#!/bin/bash
#
# Smoke test for a running ATOM Cam with atomcam_tools.
# 実機の ATOM Cam に対するスモークテスト
#
# usage: tests/device/smoke.sh [-d] [host]
#   host : default $ATOMCAM_HOST or atomcam-s1.local
#   -d   : also run disruptive checks (kill ntpd and check the watchdog restarts it)
# env  : ZOMBIE_WAIT  seconds to wait before re-checking zombie processes (default 10)
#
# SSH uses public key auth as root. If SSH_AUTH_SOCK is unset, ~/.ssh/agent.sock is used.
# Exit status: 0 if all checks passed, 1 otherwise.

DISRUPTIVE=0
while getopts d opt; do
  case $opt in
    d) DISRUPTIVE=1 ;;
    *) echo "usage: $0 [-d] [host]" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

HOST=${1:-${ATOMCAM_HOST:-atomcam-s1.local}}
ZOMBIE_WAIT=${ZOMBIE_WAIT:-10}
[ -z "$SSH_AUTH_SOCK" ] && [ -S ~/.ssh/agent.sock ] && export SSH_AUTH_SOCK=~/.ssh/agent.sock
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5 -o PubkeyAcceptedKeyTypes=ssh-rsa root@$HOST"

PASS=0
FAIL=0
SKIP=0

if [ -t 1 ]; then
  GREEN='\e[32m'; RED='\e[31m'; YELLOW='\e[33m'; RESET='\e[0m'
fi
pass() { PASS=$((PASS + 1)); printf "${GREEN}PASS${RESET} %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "${RED}FAIL${RESET} %s\n" "$1"; [ -n "$2" ] && printf '     %s\n' "$2"; }
skip() { SKIP=$((SKIP + 1)); printf "${YELLOW}SKIP${RESET} %s\n" "$1"; [ -n "$2" ] && printf '     %s\n' "$2"; }
remote() { $SSH "$1" 2> /dev/null; }

echo "=== atomcam smoke test: $HOST ==="

# --- network / web ---
if ping -c 1 -W 2 "$HOST" > /dev/null 2>&1; then
  pass "ping"
else
  fail "ping" "$HOST is unreachable"
  echo "=== aborted ==="
  exit 1
fi

res=$(curl -s --max-time 10 -w '\n%{http_code}' "http://$HOST/")
if [ "${res##*$'\n'}" = "200" ] && echo "$res" | grep -q "ATOMCam Hack Setup"; then
  pass "web: top page"
else
  fail "web: top page" "http status: ${res##*$'\n'}"
fi

ini=$(curl -s --max-time 10 "http://$HOST/cgi-bin/hack_ini.cgi")
ver=$(echo "$ini" | sed -ne 's/^ATOMHACKVER=//p')
if [ -n "$ver" ]; then
  pass "web: hack_ini.cgi (atomcam_tools Ver.$ver)"
else
  fail "web: hack_ini.cgi" "ATOMHACKVER not found"
fi

# --- ssh ---
if [ "$(remote 'echo ok')" = "ok" ]; then
  pass "ssh login"
else
  fail "ssh login" "check SSH_AUTH_SOCK and the key (ssh-add -l)"
  echo "=== aborted: $PASS passed, $FAIL failed, $SKIP skipped ==="
  exit 1
fi

# --- processes ---
ps=$(remote 'ps')
for p in iCamera_app lighttpd sshd crond ntpd avahi-daemon webhook.sh webcmd.sh; do
  if echo "$ps" | grep -v grep | grep -q "$p"; then
    pass "process: $p"
  else
    fail "process: $p" "not running"
  fi
done

# Zombies appear transiently for a while after boot.
# Only those still present after ZOMBIE_WAIT seconds are reported as failures.
zombies=$(echo "$ps" | awk '$4 ~ /^Z/ { print $1 }')
if [ -z "$zombies" ]; then
  pass "no zombie process"
else
  sleep $ZOMBIE_WAIT
  persistent=$(remote "for p in $(echo $zombies); do
    grep -q '^State:.*Z' /proc/\$p/status 2> /dev/null || continue
    pp=\$(awk '/^PPid/ { print \$2 }' /proc/\$p/status)
    echo \"\$p <- \$pp: \$(tr '\\0' ' ' < /proc/\$pp/cmdline | cut -c1-80)\"
  done")
  if [ -z "$persistent" ]; then
    pass "no zombie process ($(echo $zombies | wc -w) transient, gone after ${ZOMBIE_WAIT}s)"
  else
    fail "no zombie process" "$(echo "$persistent" | tr '\n' ';')"
  fi
fi

# --- libcallback ---
res=$(remote '/scripts/cmd audio' | tr -d '\0')
if [ "$res" = "on" -o "$res" = "off" ]; then
  pass "libcallback: /scripts/cmd responds"
else
  fail "libcallback: /scripts/cmd responds" "response: '$res'"
fi

# --- cron ---
cron=$(remote 'crontab -l')
if echo "$cron" | grep -q "/scripts/health_check.sh"; then
  pass "cron: health_check"
else
  fail "cron: health_check" "not in crontab"
fi
if remote 'grep -q watchdog /etc/init.d/S42ntpd'; then
  if echo "$cron" | grep -q "S42ntpd watchdog"; then
    pass "cron: ntpd watchdog"
  else
    fail "cron: ntpd watchdog" "S42ntpd supports watchdog but it is not in crontab"
  fi
else
  skip "cron: ntpd watchdog" "not supported by this firmware"
fi

# --- time ---
cam=$(remote 'date +%s')
now=$(date +%s)
if [ -n "$cam" ] && [ $((cam > now ? cam - now : now - cam)) -le 60 ]; then
  pass "time: synchronized (diff $((cam - now))s)"
else
  fail "time: synchronized" "camera:${cam:-?} host:$now"
fi

# --- storage / memory ---
df=$(remote 'df /media/mmc | tail -1')
use=$(echo "$df" | awk '{ sub(/%/, "", $5); print $5 }')
if [ -n "$use" ] && [ "$use" -lt 95 ]; then
  pass "sdcard: mounted (${use}% used)"
else
  fail "sdcard: mounted" "df: $df"
fi
if remote 'touch /media/mmc/.smoke_test && rm /media/mmc/.smoke_test'; then
  pass "sdcard: writable"
else
  fail "sdcard: writable"
fi

swap=$(remote 'free' | awk '/^Swap:/ { print $2 }')
if [ -n "$swap" ] && [ "$swap" -gt 0 ]; then
  pass "memory: swap enabled (${swap}KB)"
else
  fail "memory: swap enabled"
fi

# --- periodic recording ---
# A file is written for every minute: /media/mmc/record/YYYYMMDD/HH/MM.mp4
# PERIODICREC_SCHEDULE_LIST: [index_NN];Rule=<bit (1<<weekday), Mon=1..Sun=7>;ContinueTime=<min>;StartTime=<min>;...
# ContinueTime is negative when the period crosses midnight.
# Prints the minutes since the active period started, or nothing outside the schedule.
schedule_elapsed() { # list weekday(1-7) minute-of-day
  echo "$1" | tr ';' '\n' | awk -F= -v w=$2 -v m=$3 '
    function on(d) { return int(rule / 2 ^ d) % 2; }
    $1 == "Rule" { rule = $2; }
    $1 == "ContinueTime" { len = ($2 <= 0) ? $2 + 1440 : $2; }
    $1 == "StartTime" {
      if(on(w) && m >= $2 && m < $2 + len) { print m - $2; exit; }
      if(on(w == 1 ? 7 : w - 1) && m + 1440 < $2 + len) { print m + 1440 - $2; exit; }
    }'
}

if [ "$(echo "$ini" | sed -ne 's/^PERIODICREC_SDCARD=//p')" != "on" ]; then
  skip "recording: periodic recording to SD card" "PERIODICREC_SDCARD is not on"
else
  rec=$(remote 'cut -d. -f1 /proc/uptime
    date +"%u %H %M %S"
    f=$(ls -t $(find /media/mmc/record -name "*.mp4" -mmin -3) 2> /dev/null | sed -n 2p)
    echo "$f"
    [ -n "$f" ] && ls -l "$f" | awk "{ print \$5 }" && dd if="$f" bs=1 skip=4 count=4 2> /dev/null && echo
    find /media/mmc/record -name "*.mp4" -mmin -5 | wc -l')
  # seconds since recording should have started: since boot, or since the schedule period started
  started=$(echo "$rec" | sed -n 1p)
  reason="just booted"
  if [ "$(echo "$ini" | sed -ne 's/^PERIODICREC_SCHEDULE=//p')" = "on" ]; then
    set -- $(echo "$rec" | sed -n 2p)
    elapsed=$(schedule_elapsed "$(echo "$ini" | sed -ne 's/^PERIODICREC_SCHEDULE_LIST=//p')" $1 $((10#$2 * 60 + 10#$3)))
    if [ -z "$elapsed" ]; then
      started=
    elif [ $((elapsed * 60 + 10#$4)) -lt $started ]; then
      started=$((elapsed * 60 + 10#$4))
      reason="schedule just started"
    fi
  fi
  file=$(echo "$rec" | sed -n 3p)
  if [ -z "$started" ]; then
    skip "recording: periodic recording to SD card" "outside PERIODICREC_SCHEDULE_LIST"
  elif [ -z "$file" ]; then
    if [ "$started" -lt 180 ]; then
      skip "recording: periodic recording to SD card" "$reason (${started}s)"
    else
      fail "recording: periodic recording to SD card" "no mp4 file in the last 3 minutes"
    fi
  else
    size=$(echo "$rec" | sed -n 4p)
    type=$(echo "$rec" | sed -n 5p)
    count=$(echo "$rec" | sed -n 6p)
    if [ "$size" -ge 100000 ] && [ "$type" = "ftyp" ]; then
      pass "recording: periodic recording to SD card (${file#/media/mmc/record/} ${size}bytes)"
    else
      fail "recording: periodic recording to SD card" "$file size:$size type:$type"
    fi
    if [ "$started" -lt 360 ]; then
      skip "recording: no gap in the last 5 minutes" "$reason (${started}s)"
    elif [ "$count" -ge 4 ]; then
      pass "recording: no gap in the last 5 minutes ($count files)"
    else
      fail "recording: no gap in the last 5 minutes" "only $count files"
    fi
  fi
fi

# --- disruptive ---
if [ $DISRUPTIVE = 1 ]; then
  if remote 'grep -q watchdog /etc/init.d/S42ntpd'; then
    remote 'killall ntpd; sleep 1; /etc/init.d/S42ntpd watchdog > /dev/null; sleep 1'
    if remote 'pidof ntpd' > /dev/null; then
      pass "disruptive: ntpd restarted by watchdog"
    else
      fail "disruptive: ntpd restarted by watchdog" "ntpd is not running. restart: /etc/init.d/S42ntpd start"
    fi
  else
    skip "disruptive: ntpd restarted by watchdog" "not supported by this firmware"
  fi
fi

echo "=== $PASS passed, $FAIL failed, $SKIP skipped ==="
[ $FAIL = 0 ]
