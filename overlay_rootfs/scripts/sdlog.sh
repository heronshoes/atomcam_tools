#!/bin/sh
#
# Keep logs on the SD card that survive a reboot, to find the cause of an unexpected one
# (the syslog is on the RAM disk and is lost):
#   /media/mmc/sdlog/status.log    every 256 seconds, one line of counters
#   /media/mmc/sdlog/messages.log  the lines added to the syslog /tmp/log/messages (every 10 seconds)
#   /media/mmc/sdlog/ntpd.log      the clock adjustments of ntpd (written by ntpd_event.sh)
# Each write is flushed to the card (fsync), so the lines up to a few seconds before a crash or a
# watchdog reset stay. logrotate keeps them small (/etc/logrotate.d/sdlog.conf).
#
# status.log fields (the counters since boot; compare two lines for a rate):
#   up         uptime in seconds
#   load       load average 1, 5, 15 minutes
#   cpu        user,system,idle,iowait,softirq in 1/100 s
#   free cached dirty swapfree   memory in kB
#   rx tx      bytes received / sent on wlan0
#   link level wireless link quality and signal level (dBm) of wlan0
#   mmc        sectors read, sectors written, I/O in progress on the SD card
#   icam       iCamera_app pid:VmRSS in kB ("-" when it is not running)
#
# usage: sdlog.sh start|stop

DIR=/media/mmc/sdlog
PIDFILE=/var/run/sdlog.pid
# the size of /tmp/log/messages already copied
MSGPOS=/tmp/sdlog_msgpos
# seconds between the status lines, and between the copies of the syslog
STATUS_INTERVAL=256
MESSAGES_INTERVAL=10

# append <file>: append stdin to the file and write it out to the card
append() {
  cat >> $1
  # fsync through another descriptor of the same file writes out what was appended
  dd if=/dev/null of=$1 conv=notrunc,fsync 2> /dev/null
}

status() {
  pid=$(pidof iCamera_app)
  icam=-
  [ "$pid" != "" ] && icam="$pid:$(awk '/^VmRSS:/ { print $2 }' /proc/$pid/status 2> /dev/null)"
  awk -v date="$(date +"%Y/%m/%d %H:%M:%S")" -v icam="$icam" '
  FILENAME == "/proc/uptime" { up = int($1); }
  FILENAME == "/proc/loadavg" { load = $1 "," $2 "," $3; }
  FILENAME == "/proc/stat" && $1 == "cpu" { cpu = $2 "," $4 "," $5 "," $6 "," $8; }
  FILENAME == "/proc/meminfo" { mem[$1] = $2; }
  FILENAME == "/proc/net/dev" && /wlan0:/ { sub(/.*:/, ""); rx = $1; tx = $9; }
  FILENAME == "/proc/net/wireless" && /wlan0:/ { link = $3 + 0; level = $4 + 0; }
  FILENAME == "/proc/diskstats" && $3 == "mmcblk0" { mmc = $6 "," $10 "," $12; }
  END {
    printf("%s up=%d load=%s cpu=%s free=%d cached=%d dirty=%d swapfree=%d rx=%s tx=%s link=%s level=%s mmc=%s icam=%s\n",
      date, up, load, cpu, mem["MemFree:"], mem["Cached:"], mem["Dirty:"], mem["SwapFree:"],
      rx, tx, link, level, mmc, icam);
  }' /proc/uptime /proc/loadavg /proc/stat /proc/meminfo /proc/net/dev /proc/net/wireless /proc/diskstats
}

# copy the lines added to the syslog since the last time (from the start after logrotate)
messages() {
  [ -f /tmp/log/messages ] || return
  size=$(wc -c < /tmp/log/messages)
  pos=$(cat $MSGPOS 2> /dev/null)
  [ "$pos" = "" ] && pos=0
  [ $size -lt $pos ] && pos=0
  [ $size -eq $pos ] && return
  tail -c +$((pos + 1)) /tmp/log/messages | head -c $((size - pos)) | append $DIR/messages.log
  echo $size > $MSGPOS
}

loop() {
  echo "$(date +"%Y/%m/%d %H:%M:%S") boot up=$(cut -d. -f1 /proc/uptime)" | append $DIR/status.log
  echo "===== $(date +"%Y/%m/%d %H:%M:%S") boot" | append $DIR/messages.log
  next=0
  while true ; do
    up=$(cut -d. -f1 /proc/uptime)
    if [ $up -ge $next ] ; then
      status | append $DIR/status.log
      next=$((up + STATUS_INTERVAL))
    fi
    messages
    sleep $MESSAGES_INTERVAL
  done
}

case "$1" in
  start)
    [ -f $PIDFILE ] && kill -0 $(cat $PIDFILE) 2> /dev/null && exit 0
    mkdir -p $DIR
    rm -f $MSGPOS
    loop < /dev/null > /dev/null 2>&1 &
    echo $! > $PIDFILE
  ;;
  stop)
    [ -f $PIDFILE ] && kill $(cat $PIDFILE) 2> /dev/null
    rm -f $PIDFILE
  ;;
  *)
    echo "Usage: $0 {start|stop}"
    exit 1
esac
