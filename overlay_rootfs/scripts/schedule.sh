#!/bin/sh
#
# Show the time-based settings in one timeline and check them for conflicts.
#   The cron entries (REBOOT_SCHEDULE, TIMELAPSE_SCHEDULE, PRESET_SCHEDULE, /media/mmc/crontab)
#   are read from set_crontab.sh -n, so the timeline shows what cron is given.
#   The recording schedules (PERIODICREC_SCHEDULE_LIST, ALARMREC_SCHEDULE_LIST) are read from hack.ini.
#
# usage: schedule.sh [list]   the timeline of a day and the warnings
#        schedule.sh check    the warnings only (exit 1 when there is one)
#
# warnings
#   - a preset or a timelapse starts while the camera reboots
#   - a reboot stops a timelapse, or comes before its file is finished
#   - timelapses overlap, or presets run at the same minute
#   - a PRESET_SCHEDULE entry is ignored or has a command that crashes iCamera_app
#   - the installed crontab differs from hack.ini

HACK_INI=${HACK_INI:-/tmp/hack.ini}
# minutes after a reboot before iCamera_app takes commands
BOOT_MIN=2
# a preset meteor start waits until 3 minutes after boot (preset.sh)
METEOR_WAIT_MIN=3
# minutes to write the timelapse file after the last frame
TIMELAPSE_FINISH_MIN=5

MODE=${1:-list}
case "$MODE" in
  list|check) ;;
  *) echo "Usage: $0 {list|check}" ; exit 1 ;;
esac

TAB=`printf '\t'`
TMP=/tmp/schedule.$$
trap "rm -f $TMP.*" EXIT
HACK_INI=$HACK_INI /scripts/set_crontab.sh -n > $TMP.cron || exit 1
crontab -l > $TMP.installed 2> /dev/null
cmp -s $TMP.cron $TMP.installed && CRON_OK=1 || CRON_OK=0

awk -v cronok=$CRON_OK -v bootmin=$BOOT_MIN -v meteorwait=$METEOR_WAIT_MIN -v tlfinish=$TIMELAPSE_FINISH_MIN '
  # days are a string of 7 flags, Sun..Sat
  function days(field,   n, a, i, r, s, e, d, res) {
    if(field == "*") return "1111111";
    res = "0000000";
    n = split(field, a, ",");
    for(i = 1; i <= n; i++) {
      if(split(a[i], r, "-") == 2) { s = r[1]; e = r[2]; } else { s = e = a[i]; }
      for(d = s; d <= e; d++) res = setday(res, d % 7);
    }
    return res;
  }
  function setday(s, d) { return substr(s, 1, d) "1" substr(s, d + 2); }
  function hasday(s, d) { return substr(s, d + 1, 1) == "1"; }
  # the days of an event that passed midnight
  function nextdays(s) { return substr(s, 7, 1) substr(s, 1, 6); }
  function daylabel(s,   d, res) {
    if(s == "1111111") return "daily";
    res = "";
    for(d = 0; d < 7; d++) {
      if(!hasday(s, d)) continue;
      if(res != "") res = res ",";
      res = res DAYNAME[d];
    }
    return res;
  }
  function hm(m) { m = (m % 1440 + 1440) % 1440; return sprintf("%02d:%02d", int(m / 60), m % 60); }
  # 1 when the minute a (on days sa) falls in [s, s + len) (on days sb), across the week
  function inwin(sa, a, sb, s, len,   d, d2, diff) {
    for(d = 0; d < 7; d++) {
      if(!hasday(sa, d)) continue;
      for(d2 = 0; d2 < 7; d2++) {
        if(!hasday(sb, d2)) continue;
        diff = ((d * 1440 + a) - (d2 * 1440 + s)) % 10080;
        if(diff < 0) diff += 10080;
        if(diff < len) return 1;
      }
    }
    return 0;
  }
  # recording schedule rule: bit 1..7 = Mon..Sun
  function ruledays(rule,   b, res) {
    res = "0000000";
    for(b = 1; b <= 7; b++) {
      rule = int(rule / 2);
      if(rule % 2) res = setday(res, b % 7);
    }
    return res;
  }
  # tab separated: the commands of a preset contain "|"
  function row(m, d, src, text) { printf("R\t%d\t%s\t%s\t%s\n", (m % 1440 + 1440) % 1440, daylabel(m >= 1440 ? nextdays(d) : d), src, text); }
  function warn(text) { printf("W\t%s\n", text); }
  # the preset preset.sh current applies at minute m (the latest at or before m, or the last of the day)
  function currentpreset(m,   i, best, last, idx, lastIdx) {
    best = last = -1;
    for(i = 1; i <= np; i++) {
      if((pmin[i] <= m) && (pmin[i] > best)) { best = pmin[i]; idx = pn[i]; }
      if(pmin[i] > last) { last = pmin[i]; lastIdx = pn[i]; }
    }
    return idx ? idx : lastIdx;
  }
  function recsched(name, list, on,   n, e, i, f, idx, status, rule, start, len) {
    if(!on) return;
    if(SCHED[name] != "on") { row(0, "1111111", name, "recording all day"); return; }
    # [index_NN];Rule=..;ContinueTime=..;StartTime=..;Status=1;DelFlags=1; (a sentinel closes the last one)
    n = split(list ";[index_end]", e, ";");
    idx = 0;
    for(i = 1; i <= n; i++) {
      if(e[i] ~ /^\[index_/) {
        if(idx && status && (len > 0)) {
          row(start, rule, name, "start (until " hm(start + len - 1) ")");
          row(start + len, rule, name, "end (from " hm(start) ")");
        }
        idx++; status = 1; rule = "0000000"; start = 0; len = 0;
        continue;
      }
      split(e[i], f, "=");
      if(f[1] == "Rule") rule = ruledays(f[2]);
      if(f[1] == "StartTime") start = f[2] + 0;
      # negative (or 0) when the period crosses midnight
      if(f[1] == "ContinueTime") { len = f[2] + 0; if(len <= 0) len += 1440; }
      if((f[1] == "Status") || (f[1] == "DelFlags")) if(f[2] != 1) status = 0;
    }
  }

  BEGIN {
    split("Sun Mon Tue Wed Thu Fri Sat", n, " ");
    for(i = 1; i <= 7; i++) DAYNAME[i - 1] = n[i];
  }

  # the crontab made from hack.ini
  FILENAME == ARGV[1] {
    if(($0 ~ /^#/) || (NF < 6)) next;
    # the repeating system jobs (logrotate, watchdogs) are not part of the timeline
    if(($1 !~ /^[0-9]+$/) || ($2 !~ /^[0-9]+$/)) next;
    m = $2 * 60 + $1;
    d = days($5);
    cmd = $6;
    for(i = 7; i <= NF; i++) cmd = cmd " " $i;
    if($6 == "/scripts/reboot.sh") { nr++; rmin[nr] = m; rday[nr] = d; next; }
    if(($6 == "/scripts/timelapse.sh") && ($7 == "start")) { nt++; tmin[nt] = m; tday[nt] = d; tint[nt] = $8; tcnt[nt] = $9; next; }
    if(($6 == "/scripts/preset.sh") && ($7 == "run")) { np++; pmin[np] = m; pday[np] = d; pn[np] = $8; next; }
    nu++; umin[nu] = m; uday[nu] = d; ucmd[nu] = cmd;
    next;
  }

  # hack.ini
  {
    eq = index($0, "=");
    if(!eq) next;
    key = substr($0, 1, eq - 1);
    gsub(/ /, "", key);
    INI[key] = substr($0, eq + 1);
  }

  END {
    SCHED["periodic"] = INI["PERIODICREC_SCHEDULE"];
    SCHED["alarm"] = INI["ALARMREC_SCHEDHULE"];

    # PRESET_SCHEDULE entries, numbered as set_crontab.sh and preset.sh do
    n = split(INI["PRESET_SCHEDULE"], e, ";");
    for(i = 1; i <= n; i++) {
      entry = e[i];
      gsub(/^ +| +$/, "", entry);
      if(entry == "") continue;
      if(!match(entry, /^[0-9]?[0-9]:[0-5][0-9] /) || (substr(entry, 1, index(entry, ":") - 1) + 0 > 23)) {
        warn("preset " i " is ignored (not \"HH:MM <cmd>|...\"): " entry);
        continue;
      }
      PRESET[i] = substr(entry, RLENGTH + 1);
      c = PRESET[i];
      if(match(c, /video +sharp +[0-9]+/)) {
        split(substr(c, RSTART, RLENGTH), v, " ");
        if(v[3] > 128) warn("preset " i " sets video sharp " v[3] ": over 128 crashes iCamera_app (preset.sh skips it)");
      }
    }

    reboot = (INI["REBOOT"] == "on");
    timelapse = (INI["TIMELAPSE_SDCARD"] == "on") || (INI["TIMELAPSE_CIFS"] == "on");

    for(i = 1; i <= nr; i++) {
      if(!reboot) { row(rmin[i], rday[i], "reboot", "not run (REBOOT=off)"); continue; }
      row(rmin[i], rday[i], "reboot", "reboot");
      cur = currentpreset(rmin[i] + 1);
      if(cur) {
        row(rmin[i] + 1, rday[i], "boot", "preset " cur " applied again: " PRESET[cur]);
        if(PRESET[cur] ~ /meteor +start/) row(rmin[i] + meteorwait, rday[i], "boot", "meteor start of preset " cur " (waits " meteorwait " min after boot)");
      }
    }

    for(i = 1; i <= np; i++) row(pmin[i], pday[i], "preset " pn[i], PRESET[pn[i]]);

    for(i = 1; i <= nt; i++) {
      capend[i] = tmin[i] + int((tint[i] * tcnt[i] + 59) / 60);
      tlend[i] = capend[i] + tlfinish;
      if(!timelapse) { row(tmin[i], tday[i], "timelapse", "not run (TIMELAPSE_SDCARD/CIFS off)"); continue; }
      row(tmin[i], tday[i], "timelapse", "start: " tint[i] "s x " tcnt[i] " (last frame " hm(capend[i]) ")");
      row(capend[i], tday[i], "timelapse", "last frame, writing the file until " hm(tlend[i]));
    }

    recsched("periodic", INI["PERIODICREC_SCHEDULE_LIST"], (INI["PERIODICREC_SDCARD"] == "on") || (INI["PERIODICREC_CIFS"] == "on"));
    recsched("alarm", INI["ALARMREC_SCHEDULE_LIST"], (INI["ALARMREC_SDCARD"] == "on") || (INI["ALARMREC_CIFS"] == "on"));

    for(i = 1; i <= nu; i++) row(umin[i], uday[i], "crontab", ucmd[i]);

    # conflicts
    for(r = 1; r <= nr && reboot; r++) {
      for(i = 1; i <= np; i++) {
        if(!inwin(pday[i], pmin[i], rday[r], rmin[r], bootmin)) continue;
        cur = currentpreset(rmin[r] + 1);
        warn("preset " pn[i] " at " hm(pmin[i]) " runs while the camera reboots at " hm(rmin[r]) ": its commands fail" \
          (cur == pn[i] ? " (it is applied again after boot)" : " (preset " cur " is applied after boot)"));
      }
      for(i = 1; i <= nt && timelapse; i++) {
        if(inwin(tday[i], tmin[i], rday[r], rmin[r], bootmin))
          warn("timelapse at " hm(tmin[i]) " starts while the camera reboots at " hm(rmin[r]) ": it does not start");
        else if(inwin(rday[r], rmin[r], tday[i], tmin[i], capend[i] - tmin[i]))
          warn("reboot at " hm(rmin[r]) " stops the timelapse " hm(tmin[i]) "-" hm(capend[i]) " before its last frame");
        else if(inwin(rday[r], rmin[r], tday[i], capend[i], tlfinish))
          warn("reboot at " hm(rmin[r]) " comes before the timelapse file is written (last frame " hm(capend[i]) " + " tlfinish " min)");
      }
    }
    for(i = 1; i <= nt && timelapse; i++)
      for(j = 1; j <= nt; j++)
        if((i != j) && inwin(tday[j], tmin[j], tday[i], tmin[i], tlend[i] - tmin[i]))
          warn("timelapse at " hm(tmin[j]) " starts while the timelapse " hm(tmin[i]) "-" hm(tlend[i]) " runs");
    for(i = 1; i <= np; i++)
      for(j = i + 1; j <= np; j++)
        if(inwin(pday[j], pmin[j], pday[i], pmin[i], 1))
          warn("presets " pn[i] " and " pn[j] " run at the same minute " hm(pmin[i]) ": the one started later skips the rest of the other");
    if(!cronok) warn("the installed crontab differs from hack.ini (run /scripts/set_crontab.sh, or save in the Web UI)");
  }
' $TMP.cron $HACK_INI > $TMP.out

if [ "$MODE" = "list" ] ; then
  echo "TIME   DAYS                 SOURCE      ACTION"
  grep "^R$TAB" $TMP.out | sort -t "$TAB" -k 2,2n | awk -F '\t' '{
    printf("%02d:%02d  %-20s %-11s %s\n", int($2 / 60), $2 % 60, $3, $4, $5);
  }'
  echo
fi
if grep -q "^W$TAB" $TMP.out ; then
  grep "^W$TAB" $TMP.out | sed "s/^W$TAB/WARN: /"
  exit 1
fi
[ "$MODE" = "list" ] && echo "no conflicts"
exit 0
