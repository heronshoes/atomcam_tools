# Schedule: the crontab is what set_crontab.sh makes from hack.ini, schedule.sh finds no conflict,
# and schedule.cgi (the Schedule tab) shows the same timeline for the same settings. Read only.
# スケジュール: crontab が set_crontab.sh -n と同じか、schedule.sh の警告がないか、schedule.cgi が同じ表を返すか（読み出しのみ）

res=$(remote '[ -x /scripts/schedule.sh ] || exit 0
  echo yes; echo ---
  crontab -l > /tmp/crontab.$$
  /scripts/set_crontab.sh -n | diff /tmp/crontab.$$ -; rm -f /tmp/crontab.$$; echo ---
  /scripts/schedule.sh check; echo "exit $?"; echo ---
  /scripts/schedule.sh list; echo ---
  cat /tmp/hack.ini')
part() { echo "$res" | awk -v n=$1 '/^---$/ { s++; next; } s == n'; }

if [ "$(part 0)" != yes ]; then
  skip "schedule: schedule.sh" "/scripts/schedule.sh is not installed"
  return 0
fi

d=$(part 1)
if [ -z "$d" ]; then
  pass "cron: crontab is set_crontab.sh -n"
else
  fail "cron: crontab is set_crontab.sh -n" "$(echo "$d" | grep '^[<>]' | head -5 | tr '\n' ';'). update: /scripts/set_crontab.sh"
fi

c=$(part 2)
if [ "$(echo "$c" | tail -1)" = "exit 0" ]; then
  pass "schedule: schedule.sh check (no conflicts)"
else
  fail "schedule: schedule.sh check" "$(echo "$c" | sed '$d' | head -5 | tr '\n' ';')"
fi

# schedule.cgi gets the settings as the page sends them (JSON); a value with "," cannot be sent
ini=$(part 4 | grep '=')
if echo "$ini" | grep -q ','; then
  skip "web: schedule.cgi" "a value in hack.ini has ','"
else
  web=$(http /cgi-bin/schedule.cgi -X POST -H 'Content-Type: application/json' -d "$(echo "$ini" | ini_json)")
  if [ "$web" = "$(part 3)" ]; then
    pass "web: schedule.cgi (same timeline as schedule.sh list, $(echo "$web" | grep -c .) lines)"
  else
    fail "web: schedule.cgi" "differs from schedule.sh list: $(diff <(echo "$web") <(part 3) | grep '^[<>]' | head -3 | tr '\n' ';')"
  fi
fi
