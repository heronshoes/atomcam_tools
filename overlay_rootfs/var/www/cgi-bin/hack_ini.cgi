#!/bin/sh

# The page sends back the HACK_INI_VERSION it loaded. A save from a page loaded before
# hack.ini was changed (in another page, over SSH, on the SD-Card) is refused, so that
# it does not overwrite the change. A save without HACK_INI_VERSION is not checked.
version() {
  cat /media/mmc/hack.ini /tmp/hack.ini 2> /dev/null | md5sum | cut -d ' ' -f 1
}

if [ "$REQUEST_METHOD" = "POST" ]; then
  POST=/tmp/hack_ini_post.$$
  cat > $POST
  loaded=$(sed -n 's/.*"HACK_INI_VERSION" *: *"\([0-9a-f]*\)".*/\1/p' $POST)
  if [ "$loaded" != "" ] && [ "$loaded" != "$(version)" ]; then
    rm -f $POST
    echo "Status: 409 Conflict"
    echo "Cache-Control: no-cache"
    echo "Content-Type: text/plain"
    echo ""
    echo "hack.ini was changed after the page loaded it"
    exit 0
  fi
  echo "Cache-Control: no-cache"
  echo "Content-Type: text/plain"
  echo ""
  awk '
  BEGIN {
    RS="[{},]";
  }
  /^$/ { next; }
  /^appver/ { next; }
  /^PRODUCT_MODEL/ { next; }
  /^HOSTNAME/ { next; }
  /^KERNELVER/ { next; }
  /^ATOMHACKVER/ { next; }
  /^HWADDR/ { next; }
  {
    gsub(/\"[ \t]*:[ \t]*\"?/, "=");
    gsub(/\"/, "");
    if(/^HACK_INI_VERSION=/) next;
    print;
  }
  ' $POST > /media/mmc/hack.ini
  rm -f $POST
  cat /media/mmc/hack.ini > /tmp/hack.ini
  # the page saves again with this one
  echo "HACK_INI_VERSION=`version`"
  exit 0
fi

echo "Cache-Control: no-cache"
echo "Content-Type: text/plain"
echo ""

awk '/^appver/ { print }' /atom/system/bin/app.ver
awk '/^PRODUCT_MODEL/ { print }' /atom/configs/.product_config
echo "HOSTNAME=`hostname`"
echo "KERNELVER=`uname -a`"
echo "ATOMHACKVER=`cat /etc/atomhack.ver`"
echo "HACK_INI_VERSION=`version`"
ifconfig | awk '/HWaddr/ { gsub(/^.*HWaddr */, ""); print "HWADDR=" $0}'
awk '
  /^CONFIG_VER/ { next; }
  /^appver/ { next; }
  /^PRODUCT_MODEL/ { next; }
  /^HOSTNAME/ { next; }
  /^KERNELVER/ { next; }
  /^ATOMHACKVER/ { next; }
  /^HWaddr/ { next; }
  { print; }
' /tmp/hack.ini
