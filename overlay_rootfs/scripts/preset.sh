#!/bin/sh

# ex.
# PRESET_SCHEDULE=20:00 move 180 120|night off|video expr manual 2000;05:00 move 90 90|night auto|video expr auto;
#    <HH:MM> <cmd>[|<cmd>...]  Run the commands every day at HH:MM.
#    <cmd> is a libcallback command (see /scripts/cmd), e.g. move, night, video, property, jpeg.
#    meteor start          waits until 3 minutes after boot (an earlier start gets iCamera_app killed).
#                          When a later preset runs in the meantime, the rest of this preset is skipped.
#    move <pan> <tilt> [<speed>]  speed defaults to 5 (9 loses steps). The camera first returns to
#                                 0/0 to resync the position after manual moves, then approaches
#                                 the target from below so the backlash is always on the same side.
#    night ... / property nightVision ...  waits 3 seconds after it. The day/night switch happens
#                          about 1 second later and resets video aeitmax to the mode's default.
#
# PRESET_ALIAS=night move 225 140|property nightVision on|video expr auto 0 3500 3500;day move 90 90|property nightVision auto;
#    <name> <cmd>[|<cmd>...]  A command written as <name> alone runs these commands instead.
#    <name> is a letter followed by letters, digits, _ or -. An alias may use other aliases.
#    It may have the name of a libcallback command (e.g. night): "night" alone runs the alias,
#    "night on" runs the command.
#    ex. PRESET_SCHEDULE=18:00 night;05:00 day;
#
# usage: preset.sh run <n>          apply the n-th entry of PRESET_SCHEDULE (from 1)
#        preset.sh current          apply the entry in effect now (at boot)
#        preset.sh exec <cmd>[|<cmd>...]  run the commands (and aliases) now, as a preset

HACK_INI=${HACK_INI:-/tmp/hack.ini}
# the preset applied last; an earlier preset still waiting stops when it is replaced
PRESET_RUNNING=/tmp/preset_running
PRESET_SCHEDULE=$(awk '/^PRESET_SCHEDULE *=/ { sub(/^[^=]*= */, ""); print; }' $HACK_INI)
PRESET_ALIAS=$(awk '/^PRESET_ALIAS *=/ { sub(/^[^=]*= */, ""); print; }' $HACK_INI)

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

# print the commands of "<cmd>|<cmd>..." one per line, with the aliases replaced by their commands
# (an alias used alone as a command). A line starting with "!" is an error to log.
expand() {
  awk -v cmds="$1" -v aliases="$PRESET_ALIAS" '
  # "<cmd>|<cmd>..." with the aliases replaced by their commands (an alias used alone as a command),
  # until none is left. An alias used inside itself is not replaced again and becomes "!<name>".
  function expand(c,   n, m, a, ch, b, bch, x, i, j, k, w, again, r) {
    n = split(c, a, "|");
    for(i = 1; i <= n; i++) ch[i] = ",";
    again = 1;
    while(again) {
      again = 0;
      m = 0;
      for(i = 1; i <= n; i++) {
        w = a[i];
        gsub(/^[ \t]+|[ \t]+$/, "", w);
        if(w == "") continue;
        if(!(w in ALIAS)) { b[++m] = w; bch[m] = ch[i]; continue; }
        # ch: the aliases this command came from
        if(index(ch[i], "," w ",")) { b[++m] = "!" w; bch[m] = ch[i]; continue; }
        k = split(ALIAS[w], x, "|");
        for(j = 1; j <= k; j++) { b[++m] = x[j]; bch[m] = ch[i] w ","; }
        again = 1;
      }
      for(i = 1; i <= m; i++) { a[i] = b[i]; ch[i] = bch[i]; }
      n = m;
    }
    # (busybox awk takes "r (...)" for a function call)
    r = a[1];
    for(i = 2; i <= n; i++) r = r "|" a[i];
    return r;
  }
  BEGIN {
    n = split(aliases, e, ";");
    for(i = 1; i <= n; i++) {
      s = e[i];
      gsub(/^[ \t]+|[ \t]+$/, "", s);
      if(!match(s, /^[A-Za-z][A-Za-z0-9_-]*[ \t]/)) continue;
      ALIAS[substr(s, 1, RLENGTH - 1)] = substr(s, RLENGTH + 1);
    }
    n = split(expand(cmds), c, "|");
    for(i = 1; i <= n; i++) {
      if(c[i] ~ /^!/) print "!alias " substr(c[i], 2) " : uses itself";
      else print c[i];
    }
  }'
}

superseded() {
  [ "$(cat $PRESET_RUNNING 2> /dev/null)" != "$$" ]
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
      if superseded ; then
        echo `date +"%Y/%m/%d %H:%M:%S"` : skip : $* : a later preset has run
        return
      fi
    done
  fi
  if [ "$1" = "move" -a "$3" != "" ] ; then
    speed=${4:-5}
    # hit the 0/0 end stops to resync the step count, then approach the target from below
    /scripts/cmd move 0 0 $speed 0 > /dev/null
    set -- move $2 $3 $speed 0
  fi
  echo "$* : $(/scripts/cmd $*)"
  # the day/night switch comes about 1 second later and resets aeitmax; let it finish before the next command
  if [ "$1" = "night" ] || [ "$1" = "property" -a "$2" = "nightVision" -a "$3" != "" ] ; then
    sleep 3
  fi
}

# run_cmds <log header> <cmd>[|<cmd>...]
run_cmds() {
  echo `date +"%Y/%m/%d %H:%M:%S"` : $1
  echo $$ > $PRESET_RUNNING
  IFS="
"
  for cmd in $(expand "$2") ; do
    if superseded ; then
      echo `date +"%Y/%m/%d %H:%M:%S"` : skip : $cmd : a later preset has run
      continue
    fi
    if [ "${cmd#!}" != "$cmd" ] ; then
      echo "skip : ${cmd#!}"
      continue
    fi
    run_cmd "$cmd"
  done
}

apply() {
  entry=$(echo "$PRESET_SCHEDULE" | awk 'BEGIN { RS = ";"; } NR == n { print; exit; }' n=$1)
  entry=$(echo $entry)
  [ "$entry" = "" ] && echo "preset $1 : not found" && return 1
  run_cmds "preset $1 : $entry" "${entry#* }"
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
  exec)
    shift
    run_cmds "exec : $*" "$*"
  ;;
  *)
    echo "Usage: $0 {run <n>|current|exec <cmd>[|<cmd>...]}"
    exit 1
esac
