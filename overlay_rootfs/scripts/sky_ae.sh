#!/bin/sh
#
# Meter the AE on the clear night sky instead of the whole frame.
# Bright clouds and lights raise the luma of the whole frame and the AE lowers the gain, so the
# rendering of the sky (and the contrast / brightness that suit it) changes with the clouds.
# Every few seconds this reads the luma of the 15x15 AE zones (video aezone), takes the dark zones
# as the sky and gives only them weight in the AE (video aeweight). On a dark sky the gain then
# stays at its cap (video again / dgain); in twilight or moonlight the AE keeps the sky at its target.
#
# sky zones: luma <= the darkest SKY_PCT % of the zones x SKY_RATIO + SKY_MARGIN
#
# The status is logged to /media/mmc/sdlog/sky_ae.log every minute (and at start / stop):
#   sky_pNN = luma of the percentile zone, threshold, number of sky zones (of 225), brightest zone,
#   gain = total(x256), again, dgain, exposure us, AE luma
#
# usage: sky_ae.sh start|stop|status

PIDFILE=/var/run/sky_ae.pid
# iCamera_app runs in the chroot /atom: its /tmp is /atom/tmp here
ITMP=/atom/tmp
DEFAULT=$ITMP/aeweight.default
STATUS=/tmp/sky_ae.status
LOG=/media/mmc/sdlog/sky_ae.log
LOG_EVERY=60
INTERVAL=${SKY_INTERVAL:-5}
SKY_PCT=${SKY_PCT:-20}
SKY_RATIO=${SKY_RATIO:-1.25}
SKY_MARGIN=${SKY_MARGIN:-4}

log() {
  mkdir -p ${LOG%/*}
  echo "$(date +"%Y/%m/%d %H:%M:%S") $*" >> $LOG
}

loop() {
  last=
  logged=0
  while true ; do
    if [ "$(/scripts/cmd video aezone)" = "ok" ] ; then
      # the weights file and a status line: threshold, number of sky zones
      awk -v pct=$SKY_PCT -v ratio=$SKY_RATIO -v margin=$SKY_MARGIN -v w=$ITMP/sky_ae.w '
      { for(i = 1; i <= NF; i++) { n++; z[n] = $i; s[n] = $i; } }
      END {
        if(n != 225) exit 1;
        # sort a copy to find the percentile
        for(i = 2; i <= n; i++) for(j = i; j > 1 && s[j - 1] > s[j]; j--) { t = s[j]; s[j] = s[j - 1]; s[j - 1] = t; }
        k = int(n * pct / 100); if(k < 1) k = 1;
        thr = s[k] * ratio + margin;
        sky = 0; line = "";
        for(i = 1; i <= n; i++) {
          v = (z[i] <= thr) ? 8 : 0;
          if(v) sky++;
          # (busybox awk takes "line (...)" for a function call)
          if((i - 1) % 15) line = line " ";
          line = line v;
          if(i % 15 == 0) { print line > w; line = ""; }
        }
        close(w);
        printf("%d %d %d %d\n", s[k], thr, sky, s[n]);
      }' $ITMP/aezone > $STATUS.tmp && {
        cur=$(cat $ITMP/sky_ae.w)
        if [ "$cur" != "$last" ] ; then
          /scripts/cmd video aeweight set /tmp/sky_ae.w > /dev/null && last="$cur"
        fi
        line="sky_p${SKY_PCT},threshold,zones,max=$(tr ' ' ',' < $STATUS.tmp) gain=$(/scripts/cmd video gain | tr -d '\n' | tr ' ' ',')"
        echo "$(date +"%H:%M:%S") $line" > $STATUS
        now=$(cut -d. -f1 /proc/uptime)
        if [ $((now - logged)) -ge $LOG_EVERY ] ; then
          log "$line aecomp=$(/scripts/cmd video aecomp | tr -d '\n')"
          logged=$now
        fi
      }
    fi
    sleep $INTERVAL
  done
}

case "$1" in
  start)
    [ -f $PIDFILE ] && kill -0 $(cat $PIDFILE) 2> /dev/null && exit 0
    # keep the weights to restore at stop
    [ -f $DEFAULT ] || { /scripts/cmd video aeweight > /dev/null && cp $ITMP/aeweight $DEFAULT; }
    log "start"
    loop < /dev/null > /dev/null 2>&1 &
    echo $! > $PIDFILE
  ;;
  stop)
    [ -f $PIDFILE ] && kill $(cat $PIDFILE) 2> /dev/null
    rm -f $PIDFILE
    log "stop"
    [ -f $DEFAULT ] && /scripts/cmd video aeweight set /tmp/${DEFAULT##*/} > /dev/null
  ;;
  status)
    [ -f $PIDFILE ] && kill -0 $(cat $PIDFILE) 2> /dev/null && echo running || echo stopped
    cat $STATUS 2> /dev/null
  ;;
  *)
    echo "Usage: $0 {start|stop|status}"
    exit 1
esac
