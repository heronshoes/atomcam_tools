# hack.ini save conflict: hack_ini.cgi gives HACK_INI_VERSION (md5 of the SD card and /tmp copies)
# and refuses a save with a stale one. With -d, send a save with a stale version; its body is the
# current hack.ini, so even a save that is not refused leaves the same contents.
# hack.ini の保存の衝突: HACK_INI_VERSION が正しいか（-d で古い版の保存が 409 で断られ、書き込まれないか）

# read again just before the md5, as hack.ini may have been saved since the tests started
v=$(http /cgi-bin/hack_ini.cgi | sed -ne 's/^HACK_INI_VERSION=//p')
if [ -z "$v" ]; then
  skip "web: hack_ini.cgi HACK_INI_VERSION" "not supported by this build"
  return 0
fi
version() { remote 'cat /media/mmc/hack.ini /tmp/hack.ini 2> /dev/null | md5sum' | cut -d' ' -f1; }
md5=$(version)
if [ "$v" = "$md5" ]; then
  pass "web: hack_ini.cgi HACK_INI_VERSION ($v)"
else
  fail "web: hack_ini.cgi HACK_INI_VERSION" "$v, md5 of /media/mmc/hack.ini and /tmp/hack.ini $md5"
fi

# --- -d: a save with a stale version is refused ---
[ $DISRUPTIVE = 1 ] || return 0
ini=$(remote 'cat /media/mmc/hack.ini' | grep '=')
if [ -z "$ini" ] || echo "$ini" | grep -q ','; then
  skip "disruptive: hack_ini.cgi refuses a stale save" "hack.ini is empty or has a value with ','"
  return 0
fi
json=$( (echo "$ini"; echo "HACK_INI_VERSION=00000000000000000000000000000000") | ini_json)
code=$(http /cgi-bin/hack_ini.cgi -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$json")
after=$(version)
if [ "$code" = 409 ] && [ "$after" = "$md5" ]; then
  pass "disruptive: hack_ini.cgi refuses a stale save (409, hack.ini unchanged)"
else
  fail "disruptive: hack_ini.cgi refuses a stale save" "status $code, md5 $md5 -> $after"
fi
