#!/bin/sh

# ex.
# PRESET_SCHEDULE=20:00 move 180 120|night off|video expr manual 2000;05:00 move 90 90|night auto|video expr auto;
#    <HH:MM> <cmd>[|<cmd>...]  Run the commands every day at HH:MM.
#    <cmd> is a libcallback command (see /scripts/cmd), e.g. move, night, video, property, jpeg.
#    meteor start          waits until 3 minutes after boot (an earlier start gets iCamera_app killed).
#    move <pan> <tilt> [<speed>]  speed defaults to 5 (9 loses steps). The camera first returns to
#                                 0/0 to resync the position after manual moves, then approaches
#                                 the target from below so the backlash is always on the same side.
#
# usage: preset.sh run <n>    apply the n-th entry of PRESET_SCHEDULE (from 1)
#        preset.sh current    apply the entry in effect now (at boot)

HACK_INI=${HACK_INI:-/tmp/hack.ini}
PRESET_SCHEDULE=$(awk -F "=" '/^PRESET_SCHEDULE *=/ {print $2}' $HACK_INI)

# print the index of the entry whose time is the latest at or before now (wraps to the previous day)
current_index() {
  echo "$PRESET_SCHEDULE" | awk '
  BEGIN {
    RS = ";";
    best = -1;
    last = -1;
  }
  {
    i++;
    if(!match($0, /^ *[0-9]?[0-9]:[0-5][0-9] /)) next;
    split(substr($0, RSTART, RLENGTH), t, ":");
    if(t[1] > 23) next;
    m = t[1] * 60 + t[2];
    if((m <= now) && (m > best)) { best = m; idx = i; }
    if(m > last) { last = m; lastIdx = i; }
  }
  END {
    if(idx) print idx;
    else if(lastIdx) print lastIdx;
  }
  ' now=$(date +"%H %M" | awk '{print $1 * 60 + $2}')
}

run_cmd() {
  IFS=" "
  set -- $1
  [ "$1" = "" ] && return
  if [ "$1" = "video" -a "$2" = "sharp" ] && [ "$3" -gt 128 ] 2> /dev/null ; then
    echo "skip : $* : sharp over 128 crashes iCamera_app"
    return
  fi
  if [ "$1" = "meteor" -a "$2" = "start" ] ; then
    # iCamera_app gets killed when recording starts within a minute after boot; wait until up 3 minutes
    while [ "$(cut -d. -f1 /proc/uptime)" -lt 180 ] ; do
      sleep 5
    done
  fi
  if [ "$1" = "move" -a "$3" != "" ] ; then
    speed=${4:-5}
    # hit the 0/0 end stops to resync the step count, then approach the target from below
    /scripts/cmd move 0 0 $speed 0 > /dev/null
    set -- move $2 $3 $speed 0
  fi
  echo "$* : $(/scripts/cmd $*)"
}

apply() {
  entry=$(echo "$PRESET_SCHEDULE" | awk 'BEGIN { RS = ";"; } NR == n { print; exit; }' n=$1)
  entry=$(echo $entry)
  [ "$entry" = "" ] && echo "preset $1 : not found" && return 1
  echo `date +"%Y/%m/%d %H:%M:%S"` : preset $1 : $entry
  IFS="|"
  for cmd in ${entry#* } ; do
    run_cmd "$cmd"
  done
}

case "$1" in
  run)
    apply $2
  ;;
  current)
    index=$(current_index)
    [ "$index" = "" ] && exit 0
    PRODUCT_MODEL=$(awk -F "=" '/^PRODUCT_MODEL *=/ {print $2}' /atom/configs/.product_config)
    if [ "ATOM_CAKP1JZJP" = "$PRODUCT_MODEL" ] ; then
      # wait for motor_init to finish homing, or it moves the camera after us
      count=0
      while [ ! -f /tmp/motor_initialize_done -a $count -lt 120 ] ; do
        sleep 1
        let count++
      done
    fi
    apply $index
  ;;
  *)
    echo "Usage: $0 {run <n>|current}"
    exit 1
esac
