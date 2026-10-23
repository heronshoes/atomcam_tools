# SD copy of the vendor rootfs: S20mountfs refreshes atom_root.squashfs when its md5 differs
# from the flash. Read only (reads 4MB from the flash and from the SD card).
# 本体 rootfs の SD コピー: フラッシュと md5 が同じか（読み出しのみ）

res=$(remote 'dd if=/dev/mtdblock2 bs=16k count=244 2> /dev/null | md5sum; md5sum < /media/mmc/atom_root.squashfs' | cut -d' ' -f1)
set -- $res
if [ -z "$2" ]; then
  fail "rootfs: SD copy matches the flash" "could not read: '$res'"
elif [ "$1" = "$2" ]; then
  pass "rootfs: SD copy matches the flash (md5 $1)"
else
  fail "rootfs: SD copy matches the flash" "flash $1, /media/mmc/atom_root.squashfs $2"
fi
