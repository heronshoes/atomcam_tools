# video gain: the current gain and exposure from libcallback
# (total gain x256, again, dgain, exposure us, AE luma). Read only.
# video gain: 現在のゲインと露出が読めるか（読み出しのみ）

res=$(remote '/scripts/cmd video gain' | tr -d '\0' | head -1)
set -- $res
if [ "$res" = error ]; then
  skip "libcallback: video gain" "not supported by this build"
elif echo "$res" | grep -qE '^[0-9]+ [0-9]+ [0-9]+ [0-9]+ -?[0-9]+$' && [ "$1" -ge 256 ] && [ "$4" -gt 0 ]; then
  pass "libcallback: video gain (total x$(awk -v g=$1 'BEGIN { printf("%.2f", g / 256) }'), exposure ${4}us, luma $5)"
else
  fail "libcallback: video gain" "response: '$res'"
fi
