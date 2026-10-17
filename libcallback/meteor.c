/*
  usage:
   meteor start [<ch>]  : record the JPEG stream of ch (0: main, 1: sub) as MJPEG mp4
                          /media/mmc/meteor/YYYYMMDD/HH/MM.mp4 (one file per minute)
   meteor stop          : stop recording
   meteor               : status

  Every frame of the JPEG encoder is recorded with its own timestamp (variable frame rate),
  so the frame rate follows the sensor (video fps). JPEG_QUALITY in hack.ini sets the quality.
  When the free space of the SD card falls below METEOR_MIN_FREE_MB (default 2048),
  the oldest files in /media/mmc/meteor are removed.
  While recording, JPEG snapshots of the same channel are served from the recorded frames.
*/

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <fcntl.h>
#include <dirent.h>
#include <errno.h>
#include <time.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/statvfs.h>

struct channelConfigSt {
  uint dummy[4];
  int state;
  int encoder;
};

struct FrameSt {
  unsigned int offset;
  unsigned int size;
  unsigned int seq;
  long long timestamp; // us (IMP_System_GetTimeStamp)
};

struct SegmentSt {
  int fd;
  char path[64];
  int minute;
  time_t startTime;
  long long baseTimestamp;
  unsigned int mdatSize;
  int width;
  int height;
  int count;
  int alloc;
  unsigned int *sizes;
  unsigned int *times; // us from baseTimestamp
};

extern struct channelConfigSt *get_enc_chn_config(int ch);
extern int get_video_run_state(int ch);
extern void video_param_set_mutex_lock();
extern void video_param_set_mutex_unlock();
extern int IMP_Encoder_StartRecvPic(int ch);
extern int IMP_Encoder_StopRecvPic(int ch);
extern int IMP_Encoder_PollingStream(int ch, int timeoutMSec);
extern int IMP_Encoder_GetStream(int ch, uint *stream, int);
extern int IMP_Encoder_ReleaseStream(int ch, uint *stream);
extern long long IMP_System_GetTimeStamp(void);
extern char CommandResBuf[];

// IMPEncoderStream (T31) : [1] virAddr, [2] streamSize (ring buffer), [3] pack, [4] packCount, [5] seq
// IMPEncoderPack : [0] offset, [1] length, [2-3] timestamp (int64), 32 bytes
#define STREAM_VIRADDR    1
#define STREAM_SIZE       2
#define STREAM_PACK       3
#define STREAM_PACKCOUNT  4
#define STREAM_SEQ        5
#define PACK_WORDS        8

#define HACK_INI          "/tmp/hack.ini"
#define METEOR_DIR        "/media/mmc/meteor"
#define QUEUE_SIZE        (6 * 1024 * 1024)
#define QUEUE_ENTRIES     64
#define LATEST_SIZE       (1024 * 1024)
#define TIMESCALE         90000
#define MP4_TIME_OFFSET   2082844800U // 1904/01/01 - 1970/01/01

static pthread_mutex_t QueueMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t QueueCond = PTHREAD_COND_INITIALIZER;
static pthread_mutex_t LatestMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_t CaptureThread;

static unsigned char *Queue = NULL;
static struct FrameSt Frames[QUEUE_ENTRIES];
static int FrameHead = 0;
static int FrameTail = 0;
static unsigned int QueueHead = 0;

static unsigned char *Latest = NULL;
static unsigned int LatestSize = 0;

static volatile int Running = 0;   // recording is requested
static volatile int Capturing = 0; // the capture thread is running
static volatile int Active = 0;    // the writer thread is running
static int Channel = 0;
static int Encoder = -1;
static unsigned long long MinFree = 2048ULL * 1024 * 1024;
static struct SegmentSt Segment = { .fd = -1 };
static long long TimeOffset = 0; // gettimeofday - IMP_System_GetTimeStamp (us)

static unsigned int Captured = 0;
static unsigned int Written = 0;
static unsigned int Dropped = 0;
static unsigned int Skipped = 0;
static unsigned int Removed = 0;
static unsigned int LastSeq = 0;
static char Error[64] = "";

static long long GetMinFree() {

  FILE *fp = fopen(HACK_INI, "r");
  if(!fp) return 2048;
  char buf[256];
  long long mb = 2048;
  while(fgets(buf, sizeof(buf), fp)) {
    if(!strncmp(buf, "METEOR_MIN_FREE_MB=", 19)) {
      if(atoll(buf + 19) > 0) mb = atoll(buf + 19);
      break;
    }
  }
  fclose(fp);
  return mb;
}

// allocate a contiguous area in the queue (called with QueueMutex locked)
static int QueueAlloc(unsigned int size, unsigned int *offset) {

  int next = (FrameHead + 1) % QUEUE_ENTRIES;
  if(next == FrameTail) return -1;
  if(FrameHead == FrameTail) {
    if(size > QUEUE_SIZE) return -1;
    *offset = 0;
  } else {
    unsigned int tail = Frames[FrameTail].offset;
    if(QueueHead >= tail) {
      if(QueueHead + size <= QUEUE_SIZE) {
        *offset = QueueHead;
      } else if(size < tail) {
        *offset = 0;
      } else {
        return -1;
      }
    } else {
      if(QueueHead + size < tail) {
        *offset = QueueHead;
      } else {
        return -1;
      }
    }
  }
  QueueHead = *offset + size;
  return 0;
}

static void CopyStream(unsigned char *dst, uint *stream) {

  unsigned char *base = (unsigned char *)stream[STREAM_VIRADDR];
  unsigned int ringSize = stream[STREAM_SIZE];
  uint *pack = (uint *)stream[STREAM_PACK];
  for(int i = 0; i < stream[STREAM_PACKCOUNT]; i++, pack += PACK_WORDS) {
    unsigned int offset = pack[0];
    unsigned int length = pack[1];
    if(offset + length > ringSize) {
      unsigned int first = ringSize - offset;
      memcpy(dst, base + offset, first);
      memcpy(dst + first, base, length - first);
    } else {
      memcpy(dst, base + offset, length);
    }
    dst += length;
  }
}

static int StartRecvPic() {

  video_param_set_mutex_lock(1);
  int ret = IMP_Encoder_StartRecvPic(Encoder);
  video_param_set_mutex_unlock(1);
  return ret;
}

static void StopRecvPic() {

  video_param_set_mutex_lock(1);
  IMP_Encoder_StopRecvPic(Encoder);
  video_param_set_mutex_unlock(1);
}

static void *Capture(void *arg) {

  int timeouts = 0;
  while(Running) {
    if(IMP_Encoder_PollingStream(Encoder, 1000) < 0) {
      // the app may have stopped the JPEG channel; start it again
      if(++timeouts >= 2) {
        fprintf(stderr, "[meteor] polling timeout: restart ch%d\n", Channel);
        StartRecvPic();
        timeouts = 0;
      }
      continue;
    }
    timeouts = 0;
    uint stream[17];
    memset(stream, 0, sizeof(stream));
    if(IMP_Encoder_GetStream(Encoder, stream, 1) < 0) {
      fprintf(stderr, "[meteor] IMP_Encoder_GetStream(%d) failed\n", Encoder);
      usleep(10000);
      continue;
    }
    uint *pack = (uint *)stream[STREAM_PACK];
    unsigned int size = 0;
    for(int i = 0; i < stream[STREAM_PACKCOUNT]; i++) size += pack[i * PACK_WORDS + 1];
    unsigned int seq = stream[STREAM_SEQ];
    if(Captured && (seq != LastSeq + 1)) Skipped += seq - LastSeq - 1;
    LastSeq = seq;
    Captured++;

    pthread_mutex_lock(&QueueMutex);
    unsigned int offset;
    if(QueueAlloc(size, &offset) < 0) {
      Dropped++;
      pthread_mutex_unlock(&QueueMutex);
    } else {
      pthread_mutex_unlock(&QueueMutex);
      CopyStream(Queue + offset, stream);
      Frames[FrameHead].offset = offset;
      Frames[FrameHead].size = size;
      Frames[FrameHead].seq = seq;
      Frames[FrameHead].timestamp = *(long long *)(pack + 2);
      pthread_mutex_lock(&QueueMutex);
      FrameHead = (FrameHead + 1) % QUEUE_ENTRIES;
      pthread_cond_signal(&QueueCond);
      pthread_mutex_unlock(&QueueMutex);

      if(size <= LATEST_SIZE) {
        pthread_mutex_lock(&LatestMutex);
        memcpy(Latest, Queue + offset, size);
        LatestSize = size;
        pthread_mutex_unlock(&LatestMutex);
      }
    }
    IMP_Encoder_ReleaseStream(Encoder, stream);
  }

  StopRecvPic();
  pthread_mutex_lock(&QueueMutex);
  Capturing = 0;
  pthread_cond_signal(&QueueCond);
  pthread_mutex_unlock(&QueueMutex);
  return NULL;
}

static unsigned char *Put32(unsigned char *p, unsigned int v) {

  p[0] = v >> 24;
  p[1] = v >> 16;
  p[2] = v >> 8;
  p[3] = v;
  return p + 4;
}

static unsigned char *Put16(unsigned char *p, unsigned int v) {

  p[0] = v >> 8;
  p[1] = v;
  return p + 2;
}

static unsigned char *PutBox(unsigned char *p, const char *type) {

  memcpy(p + 4, type, 4);
  return p + 8;
}

static void EndBox(unsigned char *box, unsigned char *end) {

  Put32(box, end - box);
}

static unsigned char *PutMatrix(unsigned char *p) {

  static const unsigned int matrix[9] = { 0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000 };
  for(int i = 0; i < 9; i++) p = Put32(p, matrix[i]);
  return p;
}

// width/height from the SOF marker of the JPEG
static void JpegSize(unsigned char *p, unsigned int size, int *width, int *height) {

  unsigned int i = 2;
  while(i + 9 < size) {
    if(p[i] != 0xff) break;
    int marker = p[i + 1];
    int length = (p[i + 2] << 8) | p[i + 3];
    if((marker >= 0xc0) && (marker <= 0xc3)) {
      *height = (p[i + 5] << 8) | p[i + 6];
      *width = (p[i + 7] << 8) | p[i + 8];
      return;
    }
    i += 2 + length;
  }
}

static int MkDir(const char *path) {

  if(!mkdir(path, 0777) || (errno == EEXIST)) return 0;
  fprintf(stderr, "[meteor] mkdir %s : %s\n", path, strerror(errno));
  return -1;
}

static unsigned long long FreeSpace() {

  struct statvfs st;
  if(statvfs("/media/mmc", &st) < 0) return 0;
  return (unsigned long long)st.f_bavail * st.f_bsize;
}

// find the first (sorted) entry in dir; type DT_DIR or DT_REG
static int FirstEntry(const char *dir, char *name, int dirs) {

  DIR *dp = opendir(dir);
  if(!dp) return -1;
  struct dirent *ent;
  name[0] = 0;
  while((ent = readdir(dp))) {
    if(ent->d_name[0] == '.') continue;
    char path[128];
    struct stat st;
    snprintf(path, sizeof(path), "%s/%s", dir, ent->d_name);
    if(stat(path, &st) < 0) continue;
    if(dirs ? !S_ISDIR(st.st_mode) : !S_ISREG(st.st_mode)) continue;
    if(!name[0] || (strcmp(ent->d_name, name) < 0)) strncpy(name, ent->d_name, 31);
  }
  closedir(dp);
  return name[0] ? 0 : -1;
}

// remove the oldest meteor file, and its directories when they become empty
static int RemoveOldest() {

  char day[32], hour[32], file[32], path[128];
  while(1) {
    if(FirstEntry(METEOR_DIR, day, 1) < 0) return -1;
    snprintf(path, sizeof(path), METEOR_DIR "/%s", day);
    if(FirstEntry(path, hour, 1) < 0) {
      if(FirstEntry(path, file, 0) < 0) {
        if(rmdir(path) < 0) return -1;
        continue;
      }
      snprintf(path, sizeof(path), METEOR_DIR "/%s/%s", day, file);
      break;
    }
    snprintf(path, sizeof(path), METEOR_DIR "/%s/%s", day, hour);
    if(FirstEntry(path, file, 0) < 0) {
      if(rmdir(path) < 0) return -1;
      continue;
    }
    snprintf(path, sizeof(path), METEOR_DIR "/%s/%s/%s", day, hour, file);
    break;
  }
  if(!strcmp(path, Segment.path)) return -1;
  fprintf(stderr, "[meteor] remove %s\n", path);
  if(unlink(path) < 0) return -1;
  Removed++;
  char *p = strrchr(path, '/');
  *p = 0;
  if(!rmdir(path)) {
    p = strrchr(path, '/');
    *p = 0;
    rmdir(path);
  }
  return 0;
}

static int OpenSegment(struct FrameSt *frame, time_t t) {

  while(FreeSpace() < MinFree) {
    if(RemoveOldest() < 0) {
      strcpy(Error, "SD card full");
      return -1;
    }
  }

  struct tm tm;
  localtime_r(&t, &tm);
  char dir[64];
  strftime(dir, sizeof(dir), METEOR_DIR "/%Y%m%d", &tm);
  if(MkDir(METEOR_DIR) || MkDir(dir)) goto error;
  strftime(dir, sizeof(dir), METEOR_DIR "/%Y%m%d/%H", &tm);
  if(MkDir(dir)) goto error;
  snprintf(Segment.path, sizeof(Segment.path), "%s/%02d.mp4", dir, tm.tm_min);
  if(!access(Segment.path, F_OK)) {
    snprintf(Segment.path, sizeof(Segment.path), "%s/%02d_%02d.mp4", dir, tm.tm_min, tm.tm_sec);
  }
  Segment.fd = open(Segment.path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
  if(Segment.fd < 0) goto error;

  static const unsigned char header[] = {
    0x00, 0x00, 0x00, 0x1c, 'f', 't', 'y', 'p', 'i', 's', 'o', 'm', 0x00, 0x00, 0x02, 0x00,
    'i', 's', 'o', 'm', 'i', 's', 'o', '2', 'm', 'p', '4', '1',
    0x00, 0x00, 0x00, 0x08, 'm', 'd', 'a', 't',
  };
  if(write(Segment.fd, header, sizeof(header)) != sizeof(header)) {
    close(Segment.fd);
    Segment.fd = -1;
    goto error;
  }
  Segment.minute = t / 60;
  Segment.startTime = t;
  Segment.baseTimestamp = frame->timestamp;
  Segment.mdatSize = 8;
  Segment.count = 0;
  Segment.width = 0;
  Segment.height = 0;
  Error[0] = 0;
  return 0;

error:
  snprintf(Error, sizeof(Error), "open %s", strerror(errno));
  fprintf(stderr, "[meteor] open %s : %s\n", Segment.path, strerror(errno));
  return -1;
}

static int WriteFrame(struct FrameSt *frame) {

  if(Segment.count >= Segment.alloc) {
    int alloc = Segment.alloc ? Segment.alloc * 2 : 1024;
    unsigned int *sizes = realloc(Segment.sizes, alloc * sizeof(unsigned int));
    if(sizes) Segment.sizes = sizes;
    unsigned int *times = realloc(Segment.times, alloc * sizeof(unsigned int));
    if(times) Segment.times = times;
    if(!sizes || !times) return -1;
    Segment.alloc = alloc;
  }
  unsigned char *data = Queue + frame->offset;
  if(!Segment.width) JpegSize(data, frame->size, &Segment.width, &Segment.height);
  if(write(Segment.fd, data, frame->size) != frame->size) {
    snprintf(Error, sizeof(Error), "write %s", strerror(errno));
    return -1;
  }
  Segment.sizes[Segment.count] = frame->size;
  Segment.times[Segment.count] = frame->timestamp - Segment.baseTimestamp;
  Segment.count++;
  Segment.mdatSize += frame->size;
  Written++;
  return 0;
}

static void CloseSegment() {

  if(Segment.fd < 0) return;
  if(!Segment.count) {
    close(Segment.fd);
    unlink(Segment.path);
    Segment.fd = -1;
    Segment.path[0] = 0;
    return;
  }

  // sample durations in TIMESCALE; the last frame takes the previous duration
  int n = Segment.count;
  unsigned int *durations = malloc(n * sizeof(unsigned int));
  int sttsEntries = 0;
  unsigned int totalDuration = 0;
  if(durations) {
    for(int i = 0; i < n; i++) {
      if(i + 1 < n) {
        unsigned int t0 = (unsigned long long)Segment.times[i] * TIMESCALE / 1000000;
        unsigned int t1 = (unsigned long long)Segment.times[i + 1] * TIMESCALE / 1000000;
        durations[i] = t1 - t0;
      } else {
        durations[i] = (i > 0) ? durations[i - 1] : TIMESCALE / 10;
      }
      totalDuration += durations[i];
      if(!i || (durations[i] != durations[i - 1])) sttsEntries++;
    }
  }

  unsigned int moovSize = 1024 + sttsEntries * 8 + n * 8;
  unsigned char *moov = durations ? malloc(moovSize) : NULL;
  if(!moov) {
    fprintf(stderr, "[meteor] no memory for moov\n");
    free(durations);
    close(Segment.fd);
    Segment.fd = -1;
    return;
  }

  unsigned int mp4Time = Segment.startTime + MP4_TIME_OFFSET;
  unsigned int movieDuration = (unsigned long long)totalDuration * 1000 / TIMESCALE;
  unsigned char *p = moov;
  unsigned char *moovBox = p;
  p = PutBox(p, "moov");

  unsigned char *box = p;
  p = PutBox(p, "mvhd");
  p = Put32(p, 0);
  p = Put32(p, mp4Time);
  p = Put32(p, mp4Time);
  p = Put32(p, 1000);
  p = Put32(p, movieDuration);
  p = Put32(p, 0x00010000);
  p = Put16(p, 0x0100);
  memset(p, 0, 10);
  p += 10;
  p = PutMatrix(p);
  memset(p, 0, 24);
  p += 24;
  p = Put32(p, 2);
  EndBox(box, p);

  unsigned char *trak = p;
  p = PutBox(p, "trak");
  box = p;
  p = PutBox(p, "tkhd");
  p = Put32(p, 0x00000003);
  p = Put32(p, mp4Time);
  p = Put32(p, mp4Time);
  p = Put32(p, 1);
  p = Put32(p, 0);
  p = Put32(p, movieDuration);
  memset(p, 0, 16);
  p += 16;
  p = PutMatrix(p);
  p = Put32(p, Segment.width << 16);
  p = Put32(p, Segment.height << 16);
  EndBox(box, p);

  unsigned char *mdia = p;
  p = PutBox(p, "mdia");
  box = p;
  p = PutBox(p, "mdhd");
  p = Put32(p, 0);
  p = Put32(p, mp4Time);
  p = Put32(p, mp4Time);
  p = Put32(p, TIMESCALE);
  p = Put32(p, totalDuration);
  p = Put16(p, 0x55c4); // und
  p = Put16(p, 0);
  EndBox(box, p);

  box = p;
  p = PutBox(p, "hdlr");
  p = Put32(p, 0);
  p = Put32(p, 0);
  memcpy(p, "vide", 4);
  p += 4;
  memset(p, 0, 12);
  p += 12;
  memcpy(p, "VideoHandler", 13);
  p += 13;
  EndBox(box, p);

  unsigned char *minf = p;
  p = PutBox(p, "minf");
  box = p;
  p = PutBox(p, "vmhd");
  p = Put32(p, 0x00000001);
  memset(p, 0, 8);
  p += 8;
  EndBox(box, p);

  unsigned char *dinf = p;
  p = PutBox(p, "dinf");
  box = p;
  p = PutBox(p, "dref");
  p = Put32(p, 0);
  p = Put32(p, 1);
  unsigned char *url = p;
  p = PutBox(p, "url ");
  p = Put32(p, 0x00000001);
  EndBox(url, p);
  EndBox(box, p);
  EndBox(dinf, p);

  unsigned char *stbl = p;
  p = PutBox(p, "stbl");
  box = p;
  p = PutBox(p, "stsd");
  p = Put32(p, 0);
  p = Put32(p, 1);
  unsigned char *mp4v = p;
  p = PutBox(p, "mp4v");
  memset(p, 0, 6);
  p += 6;
  p = Put16(p, 1);
  memset(p, 0, 16);
  p += 16;
  p = Put16(p, Segment.width);
  p = Put16(p, Segment.height);
  p = Put32(p, 0x00480000);
  p = Put32(p, 0x00480000);
  p = Put32(p, 0);
  p = Put16(p, 1);
  memset(p, 0, 32);
  p += 32;
  p = Put16(p, 0x0018);
  p = Put16(p, 0xffff);
  unsigned char *esds = p;
  p = PutBox(p, "esds");
  p = Put32(p, 0);
  unsigned int bitrate = movieDuration ? (unsigned long long)(Segment.mdatSize - 8) * 8000 / movieDuration : 0;
  static const unsigned char es[] = { 0x03, 0x15, 0x00, 0x01, 0x00, 0x04, 0x0d, 0x6c, 0x11, 0x00, 0x00, 0x00 };
  memcpy(p, es, sizeof(es));
  p += sizeof(es);
  p = Put32(p, bitrate);
  p = Put32(p, bitrate);
  *p++ = 0x06;
  *p++ = 0x01;
  *p++ = 0x02;
  EndBox(esds, p);
  EndBox(mp4v, p);
  EndBox(box, p);

  box = p;
  p = PutBox(p, "stts");
  p = Put32(p, 0);
  p = Put32(p, sttsEntries);
  for(int i = 0; i < n; ) {
    int j = i;
    while((j < n) && (durations[j] == durations[i])) j++;
    p = Put32(p, j - i);
    p = Put32(p, durations[i]);
    i = j;
  }
  EndBox(box, p);

  box = p;
  p = PutBox(p, "stsc");
  p = Put32(p, 0);
  p = Put32(p, 1);
  p = Put32(p, 1);
  p = Put32(p, 1);
  p = Put32(p, 1);
  EndBox(box, p);

  box = p;
  p = PutBox(p, "stsz");
  p = Put32(p, 0);
  p = Put32(p, 0);
  p = Put32(p, n);
  for(int i = 0; i < n; i++) p = Put32(p, Segment.sizes[i]);
  EndBox(box, p);

  box = p;
  p = PutBox(p, "stco");
  p = Put32(p, 0);
  p = Put32(p, n);
  unsigned int offset = 0x1c + 8;
  for(int i = 0; i < n; i++) {
    p = Put32(p, offset);
    offset += Segment.sizes[i];
  }
  EndBox(box, p);

  EndBox(stbl, p);
  EndBox(minf, p);
  EndBox(mdia, p);
  EndBox(trak, p);
  EndBox(moovBox, p);

  if(write(Segment.fd, moov, p - moov) != p - moov) {
    fprintf(stderr, "[meteor] write moov %s : %s\n", Segment.path, strerror(errno));
  }
  unsigned char mdatSize[4];
  Put32(mdatSize, Segment.mdatSize);
  if(pwrite(Segment.fd, mdatSize, 4, 0x1c) != 4) {
    fprintf(stderr, "[meteor] write mdat %s : %s\n", Segment.path, strerror(errno));
  }
  close(Segment.fd);
  Segment.fd = -1;
  free(moov);
  free(durations);
}

static void UpdateTimeOffset() {

  struct timeval tv;
  gettimeofday(&tv, NULL);
  TimeOffset = (long long)tv.tv_sec * 1000000 + tv.tv_usec - IMP_System_GetTimeStamp();
}

static void *Writer(void *arg) {

  UpdateTimeOffset();
  while(1) {
    pthread_mutex_lock(&QueueMutex);
    while(Capturing && (FrameHead == FrameTail)) pthread_cond_wait(&QueueCond, &QueueMutex);
    if(FrameHead == FrameTail) {
      pthread_mutex_unlock(&QueueMutex);
      break;
    }
    struct FrameSt *frame = &Frames[FrameTail];
    pthread_mutex_unlock(&QueueMutex);

    time_t t = (frame->timestamp + TimeOffset) / 1000000;
    if((Segment.fd >= 0) && (t / 60 != Segment.minute)) {
      int minute = Segment.minute;
      CloseSegment();
      UpdateTimeOffset();
      t = (frame->timestamp + TimeOffset) / 1000000;
      // the new offset can move t back into the closed minute; keep it in the next one
      if(t / 60 <= minute) t = (time_t)(minute + 1) * 60;
    }
    if(Segment.fd < 0) OpenSegment(frame, t);
    if((Segment.fd >= 0) && (WriteFrame(frame) < 0)) {
      fprintf(stderr, "[meteor] write %s : %s\n", Segment.path, Error);
      CloseSegment();
    }

    pthread_mutex_lock(&QueueMutex);
    FrameTail = (FrameTail + 1) % QUEUE_ENTRIES;
    pthread_mutex_unlock(&QueueMutex);
  }
  pthread_join(CaptureThread, NULL);
  CloseSegment();
  fprintf(stderr, "[meteor] stop: captured %u written %u dropped %u skipped %u\n", Captured, Written, Dropped, Skipped);
  Active = 0;
  return NULL;
}

static char *Start(char *tokenPtr) {

  if(Running) return "error : already recording";
  if(Active) return "error : stopping";
  char *p = strtok_r(NULL, " \t\r\n", &tokenPtr);
  int ch = 0;
  if(p) {
    if(strcmp(p, "0") && strcmp(p, "1")) return "error : ch must be 0 or 1";
    ch = atoi(p);
  }
  struct channelConfigSt *chConfig = get_enc_chn_config(ch);
  if(!chConfig->state || (chConfig->encoder < 0)) return "error : jpeg is not enabled";
  if(get_video_run_state(ch) < 5) return "error : video is not running";

  if(!Queue) Queue = malloc(QUEUE_SIZE);
  if(!Latest) Latest = malloc(LATEST_SIZE);
  if(!Queue || !Latest) return "error : no memory";

  Channel = ch;
  Encoder = chConfig->encoder;
  MinFree = GetMinFree() * 1024 * 1024;
  FrameHead = FrameTail = 0;
  QueueHead = 0;
  LatestSize = 0;
  Captured = Written = Dropped = Skipped = Removed = 0;
  Error[0] = 0;
  if(StartRecvPic() < 0) return "error : IMP_Encoder_StartRecvPic";

  Running = Capturing = Active = 1;
  if(pthread_create(&CaptureThread, NULL, Capture, NULL)) {
    Running = Capturing = Active = 0;
    StopRecvPic();
    return "error : pthread_create";
  }
  pthread_t writer;
  if(pthread_create(&writer, NULL, Writer, NULL)) {
    Running = 0;
    pthread_join(CaptureThread, NULL);
    Active = 0;
    return "error : pthread_create";
  }
  pthread_detach(writer);
  fprintf(stderr, "[meteor] start ch%d encoder %d\n", Channel, Encoder);
  return "ok";
}

// the writer thread closes the file after the queued frames are written
static char *Stop() {

  Running = 0;
  return "ok";
}

static char *Status() {

  int queued = (FrameHead - FrameTail + QUEUE_ENTRIES) % QUEUE_ENTRIES;
  snprintf(CommandResBuf, 255, "%s ch%d %s captured %u written %u dropped %u skipped %u queued %d removed %u%s%s",
    Running ? "recording" : Active ? "stopping" : "stopped", Channel, Active ? Segment.path : "-", Captured, Written, Dropped, Skipped,
    queued, Removed, Error[0] ? " error : " : "", Error);
  return CommandResBuf;
}

char *Meteor(int fd, char *tokenPtr) {

  char *p = strtok_r(NULL, " \t\r\n", &tokenPtr);
  if(!p) return Status();
  if(!strcasecmp(p, "start")) return Start(tokenPtr);
  if(!strcasecmp(p, "stop")) return Stop();
  return "error";
}

int MeteorRecording(int ch) {

  return Capturing && (ch == Channel);
}

// serve a JPEG snapshot from the recorded frames while ch is recorded
// return -1 when ch is not recorded, -2 on error
int MeteorWriteJpeg(int ch, int fd, const char *header) {

  if(!Capturing || (ch != Channel)) return -1;
  unsigned char *buf = malloc(LATEST_SIZE);
  if(!buf) return -2;
  unsigned int size = 0;
  for(int i = 0; (i < 20) && !size; i++) {
    if(i) usleep(100000);
    pthread_mutex_lock(&LatestMutex);
    size = LatestSize;
    if(size) memcpy(buf, Latest, size);
    pthread_mutex_unlock(&LatestMutex);
  }
  int ret = -2;
  if(size) {
    if(header) write(fd, header, strlen(header));
    if(write(fd, buf, size) == size) ret = 0;
  }
  free(buf);
  return ret;
}
