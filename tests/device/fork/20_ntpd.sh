# ntpd: the time sync at boot waits for the network, and the cron watchdog restarts a stopped ntpd.
# With -d, stop ntpd and wait for the watchdog to restart it.
# ntpd: 起動時の同期と cron の watchdog（-d で ntpd を止めて watchdog が再起動するか確かめる）

res=$(remote 'grep -c watchdog /etc/init.d/S42ntpd; echo ---; crontab -l; echo ---
  cut -d. -f1 /proc/uptime; [ -f /tmp/ntpd_waiting ] && echo waiting; echo ---
  awk "/ntpd sync/ { s = \$0 } /Reboot & Start watchdog/ { b = s; s = \"\" } END { print b }" /media/mmc/atomhack.log')
part() { echo "$res" | awk -v n=$1 '/^---$/ { s++; next; } s == n'; }

if [ "$(part 0)" = 0 ]; then
  skip "ntpd: watchdog" "S42ntpd has no watchdog"
  return 0
fi

l="* * * * * /etc/init.d/S42ntpd watchdog >> /media/mmc/atomhack.log"
if part 1 | grep -qxF "$l"; then
  pass "cron: S42ntpd watchdog"
else
  fail "cron: S42ntpd watchdog" "not in crontab: $l"
fi

# the background sync after a boot without the network gives up after about 3 minutes
set -- $(part 2)
if [ "$2" = waiting ] && [ "$1" -gt 240 ]; then
  fail "ntpd: boot sync finished" "/tmp/ntpd_waiting remains ${1}s after boot"
elif [ "$2" = waiting ]; then
  skip "ntpd: boot sync finished" "still waiting for the network (${1}s after boot)"
else
  pass "ntpd: boot sync finished"
fi

# the record of the last boot (S42ntpd logs it before the watchdog line)
sync=$(part 3)
case "$sync" in
  *"ntpd synced ("*|*"ntpd synced late ("*) pass "ntpd: synced at the last boot (${sync#*: })" ;;
  *"ntpd sync failed"*) fail "ntpd: synced at the last boot" "$sync" ;;
  *) skip "ntpd: synced at the last boot" "no record in atomhack.log" ;;
esac

# --- -d: stop ntpd and wait for the watchdog (every minute) to restart it ---
[ $DISRUPTIVE = 1 ] || return 0
remote 'killall ntpd'
t0=$(date +%s)
pid=
while [ $(($(date +%s) - t0)) -lt 75 ]; do
  sleep 5
  pid=$(remote 'pidof ntpd')
  [ -n "$pid" ] && break
done
if [ -n "$pid" ]; then
  pass "disruptive: ntpd restarted by the watchdog (after $(($(date +%s) - t0))s)"
else
  fail "disruptive: ntpd restarted by the watchdog" "not running after 75s. restart: /usr/sbin/ntpd -p ntp.nict.jp"
fi
