#!/bin/sh
#
# POST: the timeline and warnings of the settings sent by the page (JSON as hack_ini.cgi),
#       including the changes not saved yet (/scripts/schedule.sh list)

echo "Cache-Control: no-cache"
echo "Content-Type: text/plain"
echo ""

[ "$REQUEST_METHOD" = "POST" ] || exit 0
INI=/tmp/schedule_preview.$$
awk '
BEGIN {
  RS="[{},]";
}
/^$/ { next; }
{
  gsub(/\"[ \t]*:[ \t]*\"?/, "=");
  gsub(/\"/, "");
  print;
}
' > $INI
HACK_INI=$INI /scripts/schedule.sh list
rm -f $INI
