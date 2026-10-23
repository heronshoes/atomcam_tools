# Presets: the last preset in atomhack.log is the one in effect now (preset.sh runs it from cron,
# and the current one at boot), and none of its commands returned an error. Read only.
# プリセット: atomhack.log の最後のプリセットが今の時刻のものか、コマンドがエラーになっていないか（読み出しのみ）

schedule=$(ini_get PRESET_SCHEDULE)
if [ -z "$schedule" ]; then
  skip "preset: current preset applied" "PRESET_SCHEDULE is not set"
  return 0
fi

res=$(remote 'date +"%H %M"; cut -d. -f1 /proc/uptime; echo ---; tail -400 /media/mmc/atomhack.log')
set -- $(echo "$res" | sed -n 1p)
now=$((10#$1 * 60 + 10#$2))
up=$(echo "$res" | sed -n 2p)
log=$(echo "$res" | sed '1,/^---$/d')

# current: "<index> <minutes since its time>" of the entry in effect now, as preset.sh current
current=$(echo "$schedule" | awk -v now=$now '
  BEGIN { RS = ";"; best = -1; last = -1; }
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
    if(idx) print idx, now - best;
    else if(lastIdx) print lastIdx, now + 1440 - last;
  }')
set -- $current
cur=$1 since=$2

# the last preset block: the header line and the "<command> : <result>" lines after it
block=$(echo "$log" | awk '
  / : preset [0-9]+ : / { b = $0; inb = 1; next; }
  inb && /^[0-9][0-9][0-9][0-9]\// { inb = 0; }
  inb && / : / { b = b "\n" $0; next; }
  { inb = 0; }
  END { print b; }')
n=$(echo "$block" | sed -n '1s/.* : preset \([0-9]*\) : .*/\1/p')

if [ -z "$n" ]; then
  skip "preset: current preset applied" "no preset in the end of atomhack.log"
elif [ "$n" != "$cur" ] && { [ "$since" -lt 2 ] || [ "$up" -lt 240 ]; }; then
  skip "preset: current preset applied" "preset $cur may be running now"
elif [ "$n" != "$cur" ]; then
  fail "preset: current preset applied" "last applied preset $n, in effect now preset $cur"
else
  pass "preset: current preset applied (preset $n: $(echo "$block" | sed -n '1s/.* : preset [0-9]* : //p'))"
  errors=$(echo "$block" | sed 1d | grep -E ' : (error.*)?$')
  if [ -z "$errors" ]; then
    pass "preset: commands of preset $n succeeded ($(echo "$block" | sed 1d | grep -c .) commands)"
  else
    fail "preset: commands of preset $n succeeded" "$(echo "$errors" | tr '\n' ';')"
  fi
fi
