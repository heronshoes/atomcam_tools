#include <stdio.h>
#include <dlfcn.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

static int (*real_local_sdk_video_get_jpeg)(int ch, char *path);
static int skipRecordJpeg = 0;

extern int MeteorRecording(int ch);
extern int MeteorWriteJpeg(int ch, int fd, const char *header);

static void __attribute ((constructor)) get_jpeg_init(void) {

  real_local_sdk_video_get_jpeg = dlsym(dlopen("/system/lib/liblocalsdk.so", RTLD_LAZY), "local_sdk_video_get_jpeg");
}

int local_sdk_video_get_jpeg(int ch, char *path) {

  if(skipRecordJpeg && !strncmp(path, "/media/mmc/record", 16)) {
    printf("skip local_sdk_video_get_jpeg : ch%d %s\n", ch, path);
    return 0;
  }

  // the JPEG channel is streamed by the meteor recorder
  if(MeteorRecording(ch)) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    int res = (fd >= 0) ? MeteorWriteJpeg(ch, fd, NULL) : -2;
    if(fd >= 0) close(fd);
    fprintf(stderr, "local_sdk_video_get_jpeg (meteor) %d %d %s\n", res, ch, path);
    return res ? -1 : 0;
  }

  int ret = real_local_sdk_video_get_jpeg(ch, path);
  fprintf(stderr, "local_sdk_video_get_jpeg %d %d %s\n", ret, ch, path);
  return ret;
}

char *SkipRecordJpeg(int fd, char *tokenPtr) {

  char *p = strtok_r(NULL, " \t\r\n", &tokenPtr);
  if(!p) return skipRecordJpeg ? "on" : "off";

  if(!strcasecmp(p, "on")) {
    skipRecordJpeg = 1;
    return "ok";
  } else if(!strcasecmp(p, "off")) {
    skipRecordJpeg = 0;
    return "ok";
  }
  return "error";
}
