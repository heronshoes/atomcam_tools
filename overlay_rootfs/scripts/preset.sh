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
# At boot (preset.sh current) the presets since the last scheduled reboot (REBOOT_SCHEDULE) run
# again in time order, so that a preset which relies on an earlier one (e.g. 18:00 night settings,
# then 21:30 meteor start) gets the same camera state after an unexpected reboot. With no scheduled
# reboot in the last 24 hours, all the presets run, oldest first. With no preset since that reboot
# (the boot after the scheduled reboot itself), the preset in effect now runs.
# From the earlier presets, move and meteor run only when no later preset has one (the last one
# decides the state), and commands that act once (jpeg, aplay, relmove, contmove, contstop) do not run.
#
# usage: preset.sh run <n>          apply the n-th entry of PRESET_SCHEDULE (from 1)
#        preset.sh current [-n]     at boot: run the presets again up to the one in effect now
#                                   (-n prints the commands without running them)
#        preset.sh exec <cmd>[|<cmd>...]  run the commands (and aliases) now, as a preset

HACK_INI=${HACK_INI:-/tmp/hack.ini}
# the preset applied last; an earlier preset still waiting stops when it is replaced
PRESET_RUNNING=${PRESET_RUNNING:-/tmp/preset_running}
PRESET_SCHEDULE=$(awk '/^PRESET_SCHEDULE *=/ { sub(/^[^=]*= */, ""); print; }' $HACK_INI)
PRESET_ALIAS=$(awk '/^PRESET_ALIAS *=/ { sub(/^[^=]*= */, ""); print; }' $HACK_INI)
REBOOT=$(awk -F "=" '/^REBOOT *=/ {print $2}' $HACK_INI)
REBOOT_SCHEDULE=$(awk -F "=" '/^REBOOT_SCHEDULE *=/ {print $2}' $HACK_INI)
DRYRUN=

# print the indexes of the entries to run at boot in time order, the one in effect now last:
# the entries since the last scheduled reboot, or all of the last 24 hours when there was none,
# or the one in effect now when none ran since the reboot.
# (the one in effect: the latest at or before now, wrapping to the previous day; of two at the same
# time, the first one)
day_order() {
  set -- $(date +"%w %H %M")
  echo "$PRESET_SCHEDULE" | awk -v wday=$1 -v hh=$2 -v mm=$3 -v reboot="$REBOOT" -v rsched="$REBOOT_SCHEDULE" '
  # whether the cron day field d (e.g. 1:2:3 or *) has the weekday w (0 = Sunday, also 7)
  function hasday(d, w) {
    if(d == "*") return 1;
    gsub(/,/, ":", d);
    return index(":" d ":", ":" w ":") || ((w == 0) && index(":" d ":", ":7:"));
  }
  BEGIN {
    RS = ";";
    now = hh * 60 + mm;
    # minutes since the last scheduled reboot, -1 when none in the last 24 hours
    rage = -1;
    if((reboot == "on") && (split(rsched, r, " ") >= 5) && (r[1] ~ /^[0-9]+$/) && (r[2] ~ /^[0-9]+$/)) {
      rmin = r[2] * 60 + r[1];
      if(rmin <= now) {
        if(hasday(r[5], wday)) rage = now - rmin;
      } else {
        if(hasday(r[5], (wday + 6) % 7)) rage = now - rmin + 1440;
      }
    }
  }
  {
    i++;
    if(!match($0, /^ *[0-9]?[0-9]:[0-5][0-9] /)) next;
    split(substr($0, RSTART, RLENGTH), t, ":");
    if(t[1] > 23) next;
    n++;
    idx[n] = i;
    # minutes since the entry ran last
    age[n] = (now - (t[1] * 60 + t[2]) + 1440) % 1440;
  }
  END {
    # oldest first; at the same age the later entry first, so that the first one is in effect
    for(j = 2; j <= n; j++)
      for(k = j; (k > 1) && ((age[k - 1] < age[k]) || ((age[k - 1] == age[k]) && (idx[k - 1] < idx[k]))); k--) {
        a = age[k]; age[k] = age[k - 1]; age[k - 1] = a;
        a = idx[k]; idx[k] = idx[k - 1]; idx[k - 1] = a;
      }
    if(!n) exit;
    first = 1;
    if(rage >= 0) {
      first = n;
      for(j = 1; j <= n; j++) if(age[j] <= rage) { first = j; break; }
    }
    for(j = first; j <= n; j++) print idx[j];
  }'
}

# replay_cmds <current index>: read "<index> <tab> <command>" lines in time order and print the ones
# to run again at boot: all of the current preset; from the earlier ones, not the commands that act
# once, and move / meteor only when no later preset has one
replay_cmds() {
  awk -F "\t" -v cur=$1 '
  { idx[NR] = $1; cmd[NR] = $2; }
  END {
    once["jpeg"] = once["aplay"] = once["relmove"] = once["contmove"] = once["contstop"] = 1;
    last["move"] = last["meteor"] = 1;
    for(i = NR; i >= 1; i--) {
      split(cmd[i], w, " ");
      keep[i] = 1;
      if(idx[i] != cur) {
        if(w[1] in once) keep[i] = 0;
        if((w[1] in last) && (w[1] in seen)) keep[i] = 0;
      }
      if(w[1] in last) seen[w[1]] = 1;
    }
    for(i = 1; i <= NR; i++) if(keep[i]) print idx[i] "\t" cmd[i];
  }'
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
  [ -z "$DRYRUN" ] && [ "$(cat $PRESET_RUNNING 2> /dev/null)" != "$$" ]
}

run_cmd() {
  IFS=" "
  set -- $1
  [ "$1" = "" ] && return
  if [ "$1" = "video" -a "$2" = "sharp" ] && [ "$3" -gt 128 ] 2> /dev/null ; then
    echo "skip : $* : sharp over 128 crashes iCamera_app"
    return
  fi
  if [ "$DRYRUN" ] ; then
    echo "$* : (not run)"
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

# run_cmds <log header> <commands, one per line as expand prints them>
run_cmds() {
  echo `date +"%Y/%m/%d %H:%M:%S"` : $1
  [ "$DRYRUN$REPLAYING" ] || echo $$ > $PRESET_RUNNING
  IFS="
"
  for cmd in $2 ; do
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

# entry <n>: print the n-th entry of PRESET_SCHEDULE ("HH:MM <cmd>|...")
entry() {
  echo $(echo "$PRESET_SCHEDULE" | awk 'BEGIN { RS = ";"; } NR == n { print; exit; }' n=$1)
}

apply() {
  entry=$(entry $1)
  [ "$entry" = "" ] && echo "preset $1 : not found" && return 1
  run_cmds "preset $1 : $entry" "$(expand "${entry#* }")"
}

# replay: run the presets of the last 24 hours again in time order, up to the one in effect now
replay() {
  order=$(day_order)
  [ "$order" = "" ] && return 0
  cur=$(echo "$order" | tail -n 1)
  TAB=`printf '\t'`
  cmds=$(for i in $order ; do
    entry=$(entry $i)
    expand "${entry#* }" | sed "s/^/$i$TAB/"
  done | replay_cmds $cur)
  [ "$DRYRUN" ] || echo $$ > $PRESET_RUNNING
  REPLAYING=1
  for i in $order ; do
    if superseded ; then
      echo `date +"%Y/%m/%d %H:%M:%S"` : skip : preset $i : a later preset has run
      continue
    fi
    entry=$(entry $i)
    header="preset $i : $entry"
    [ "$i" != "$cur" ] && header="$header (again at boot, before preset $cur)"
    run_cmds "$header" "$(echo "$cmds" | awk -F "\t" -v i=$i '$1 == i { print $2 }')"
  done
}

case "$1" in
  run)
    apply $2
  ;;
  current)
    [ "$2" = "-n" ] && DRYRUN=1
    [ "$(day_order)" = "" ] && exit 0
    PRODUCT_MODEL=$(awk -F "=" '/^PRODUCT_MODEL *=/ {print $2}' /atom/configs/.product_config)
    if [ "ATOM_CAKP1JZJP" = "$PRODUCT_MODEL" -a -z "$DRYRUN" ] ; then
      # wait for motor_init to finish homing, or it moves the camera after us
      count=0
      while [ ! -f /tmp/motor_initialize_done -a $count -lt 120 ] ; do
        sleep 1
        let count++
      done
    fi
    replay
  ;;
  exec)
    shift
    run_cmds "exec : $*" "$(expand "$*")"
  ;;
  *)
    echo "Usage: $0 {run <n>|current [-n]|exec <cmd>[|<cmd>...]}"
    exit 1
esac
