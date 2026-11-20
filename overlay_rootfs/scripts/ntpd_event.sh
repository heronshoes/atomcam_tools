#!/bin/sh
#
# Run by ntpd -S (S42ntpd) to keep the clock adjustments on the SD card.
#   $1: step (the clock was set, offset is the step), stratum (the stratum changed),
#       unsync (no server answers) or periodic (every 11 minutes)
#   offset, stratum, freq_drift_ppm, poll_interval: from ntpd in the environment
# A step during a recording (e.g. the clock went back 2 s at 02:11 on 2026-11-08) shows here.

LOG=/media/mmc/sdlog/ntpd.log

# ntpd starts before the time zone is set (S43timezone.env); use it as log_time of S42ntpd does
[ -f /etc/environment ] && . /etc/environment
[ -f /media/mmc/TZ ] && TZ=`cat /media/mmc/TZ`
export TZ

mkdir -p ${LOG%/*}
echo "$(date +"%Y/%m/%d %H:%M:%S") : $1 offset=$offset stratum=$stratum drift=$freq_drift_ppm poll=$poll_interval" >> $LOG
dd if=/dev/null of=$LOG conv=notrunc,fsync 2> /dev/null
exit 0
