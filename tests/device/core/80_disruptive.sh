# Disruptive checks (-d): change the camera state and restore it.
# The video and motor checks are skipped while a busy hook reports a recording.
# 停止を伴う確認（-d）: カメラの状態を変えて元に戻す。撮影中は映像とモーターの確認を飛ばす

[ $DISRUPTIVE = 1 ] || return 0

# --- lighttpd restart (the web UI is down for a moment) ---
remote '/scripts/lighttpd.sh restart > /dev/null 2>&1'
for i in 1 2 3 4 5 6 7 8 9 10; do
  code=$(http / -o /dev/null -w '%{http_code}')
  [ "$code" = 200 ] && break
  sleep 1
done
if [ "$code" = 200 ]; then
  pass "disruptive: lighttpd restart (web up after ${i}s)"
else
  fail "disruptive: lighttpd restart" "web status $code after 10s. restart: /scripts/lighttpd.sh restart"
fi

reason=$(busy | tr '\n' ',' | sed 's/,$//')

# --- video bri: set, read back and restore ---
if [ -n "$reason" ]; then
  skip "disruptive: video bri set and restore" "$reason"
else
  bri=$(remote '/scripts/cmd video bri' | tr -d '\0')
  if ! echo "$bri" | grep -qE '^[0-9]+$'; then
    fail "disruptive: video bri set and restore" "video bri: '$bri'"
  else
    t=$((bri >= 128 ? bri - 10 : bri + 10))
    res=$(remote "/scripts/cmd video bri $t > /dev/null; /scripts/cmd video bri; /scripts/cmd video bri $bri > /dev/null; /scripts/cmd video bri" | tr -d '\0')
    set -- $res
    if [ "$1" = "$t" ] && [ "$2" = "$bri" ]; then
      pass "disruptive: video bri set and restore ($bri -> $t -> $bri)"
    else
      fail "disruptive: video bri set and restore" "set $t read '$1', restore $bri read '$2'. restore: /scripts/cmd video bri $bri"
    fi
  fi
fi

# --- motor (-m): move through the whole range and back to the original position ---
# Checks that move answers and reports the commanded position. 0, 355 and 180 are beyond the
# mechanical stops, so the step count is synced at the ends on the way. The position is the step
# count, not the view: the backlash (pan about 5 degrees) may shift the view after the return.
# Speed 5 (speed 9 loses steps). The angle is truncated to steps, so a read position is
# commanded with +0.01.
if [ "$(ini_get PRODUCT_MODEL)" != ATOM_CAKP1JZJP ]; then
  :
elif [ $MOTOR != 1 ]; then
  skip "disruptive: motor move through the range" "use -m to move the motor"
elif [ -n "$reason" ]; then
  skip "disruptive: motor move through the range" "$reason"
else
  set -- $(remote '/scripts/cmd move' | tr -d '\0')
  pan=$1 tilt=$2
  if ! echo "$pan $tilt" | grep -qE '^[0-9.]+ [0-9.]+$'; then
    fail "disruptive: motor move through the range" "move: '$*'"
  else
    back=$(awk -v p=$pan -v t=$tilt 'BEGIN { printf("%.2f %.2f", p + 0.01, t + 0.01) }')
    route=
    err=
    for to in "0 0" "0 90" "180 90" "355 90" "355 180" "0 0" "$back"; do
      res=$(remote "/scripts/cmd move $to 5 0" | tr -d '\0')
      set -- $to
      ok=$(echo "$res" | awk -v p=$1 -v t=$2 '{
        e1 = $1 - p; e2 = $2 - t; if(e1 < 0) e1 = -e1; if(e2 < 0) e2 = -e2;
        print ($1 ~ /^[0-9.]+$/ && e1 < 0.2 && e2 < 0.2) ? 1 : 0 }')
      route="$route -> $(echo "$res" | awk '{ printf("%.1f/%.1f", $1, $2) }')"
      [ "$ok" = 1 ] || { err="move $to: '$res'"; break; }
    done
    if [ -z "$err" ]; then
      pass "disruptive: motor move through the range ($pan/$tilt$route)"
    else
      fail "disruptive: motor move through the range" "$err. restore: /scripts/cmd move $back 5 0"
    fi
  fi
fi
