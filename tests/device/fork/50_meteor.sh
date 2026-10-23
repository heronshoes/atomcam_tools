# Meteor recorder: the status, the recording expected by the presets, and the file growing while
# recording. With -d (not busy), record for a few seconds, stop, and remove the test files.
# 流星撮影: 状態、プリセットどおりに撮影しているか、撮影中のファイルが増えているか
# （-d で数秒撮影して止め、試験のファイルを消す）

status() { remote '/scripts/cmd meteor' | tr -d '\0' | head -1; }
st=$(status)
if [ "$st" = error ] || [ -z "$st" ]; then
  skip "meteor: status" "the meteor command is not supported by this build"
  return 0
fi
NUM='[0-9]+'
if echo "$st" | grep -qE "^(recording|stopping|stopped) ch[01] [^ ]+ captured $NUM written $NUM dropped $NUM skipped $NUM queued $NUM removed $NUM"; then
  pass "meteor: status (${st%% captured*})"
else
  fail "meteor: status" "response: '$st'"
  return 0
fi

# expected: start or stop by the latest meteor command of the presets before now (wraps to the previous day)
res=$(remote 'date +"%H %M"; cut -d. -f1 /proc/uptime')
set -- $res
now=$((10#$1 * 60 + 10#$2)) up=$3
set -- $(ini_get PRESET_SCHEDULE | awk -v now=$now '
  BEGIN { RS = ";"; best = 9999; }
  match($0, /^ *[0-9]?[0-9]:[0-5][0-9] /) && match($0, /meteor (start|stop)/) {
    c = substr($0, RSTART + 7, RLENGTH - 7);
    match($0, /[0-9]?[0-9]:[0-5][0-9]/);
    split(substr($0, RSTART, RLENGTH), t, ":");
    d = (now - (t[1] * 60 + t[2]) + 1440) % 1440;
    if(d < best) { best = d; cmd = c; }
  }
  END { if(cmd != "") print cmd, best; }')
want=$1 since=$2
recording=${st%% *}
if [ -z "$want" ]; then
  skip "meteor: recording as the presets" "no meteor start or stop in PRESET_SCHEDULE"
elif [ "$want" = start ] && [ "$recording" != recording ]; then
  # preset.sh waits until 3 minutes after boot before starting
  if [ "$since" -lt 2 ] || [ "$up" -lt 240 ]; then
    skip "meteor: recording as the presets" "starting now (${since} minutes after the preset, up ${up}s)"
  else
    fail "meteor: recording as the presets" "a preset started it ${since} minutes ago, but: $st"
  fi
elif [ "$want" = stop ] && [ "$recording" = recording ]; then
  skip "meteor: recording as the presets" "recording, but a preset stopped it ${since} minutes ago (started by hand?)"
else
  pass "meteor: recording as the presets ($recording, preset meteor $want ${since} minutes ago)"
fi

# while recording, the written frames increase
if [ "$recording" = recording ]; then
  w1=$(echo "$st" | sed -ne 's/.* written \([0-9]*\) .*/\1/p')
  sleep 3
  st2=$(status)
  w2=$(echo "$st2" | sed -ne 's/.* written \([0-9]*\) .*/\1/p')
  dropped=$(echo "$st2" | sed -ne 's/.* dropped \([0-9]*\) .*/\1/p')
  if [ -n "$w2" ] && [ "$w2" -gt "$w1" ]; then
    pass "meteor: frames written ($((w2 - w1)) in 3s, dropped $dropped in total)"
  else
    fail "meteor: frames written" "written $w1 -> ${w2:-?} in 3s: $st2"
  fi
fi

# --- -d: record a few seconds, stop, and remove the files of the test ---
[ $DISRUPTIVE = 1 ] || return 0
reason=$(busy | tr '\n' ',' | sed 's/,$//')
if [ -n "$reason" ]; then
  skip "disruptive: meteor start and stop" "$reason"
  return 0
fi
marker=/tmp/meteor_test.$$
res=$(remote "touch $marker; sleep 1; /scripts/cmd meteor start 0; echo; sleep 5; /scripts/cmd meteor; echo; /scripts/cmd meteor stop" | tr -d '\0' | grep -v '^$')
started=$(echo "$res" | sed -n 1p)
during=$(echo "$res" | sed -n 2p)
for i in 1 2 3 4 5 6 7 8 9 10; do
  st=$(status)
  [ "${st%% *}" = stopped ] && break
  sleep 1
done
files=$(remote "find /media/mmc/meteor -type f -newer $marker; rm -f $marker")
head=$(remote "for f in $(echo $files); do dd if=\$f bs=4 skip=1 count=1 2> /dev/null; echo; done" | sort -u | tr '\n' ' ')
written=$(echo "$during" | sed -ne 's/.* written \([0-9]*\) .*/\1/p')
if [ "$started" = ok ] && [ "${during%% *}" = recording ] && [ "${written:-0}" -gt 0 ] && [ "${st%% *}" = stopped ] &&
   [ -n "$files" ] && [ "$head" = "ftyp " ]; then
  pass "disruptive: meteor start and stop (written $written frames in 5s, $(echo "$files" | wc -l) file)"
else
  fail "disruptive: meteor start and stop" "start: '$started', after 5s: '$during', after stop: '$st', files: $(echo $files), header: '$head'"
fi
[ "${st%% *}" = stopped ] || remote '/scripts/cmd meteor stop > /dev/null'
# remove the test files and the hour and day directories left empty (meteor/YYYYMMDD/HH)
if [ -n "$files" ]; then
  hours=$(echo "$files" | xargs -n 1 dirname | sort -u)
  days=$(echo "$hours" | xargs -n 1 dirname | sort -u)
  remote "rm -f $(echo $files); rmdir $(echo $hours) $(echo $days) 2> /dev/null"
fi
