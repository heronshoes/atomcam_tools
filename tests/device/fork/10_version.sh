# Custom build version: ATOMHACKVER has .custom_<commit> of a commit in this repository. Read only.
# 独自ビルドのバージョン: ATOMHACKVER の .custom_<commit> がこのリポジトリのコミットか（読み出しのみ）

ver=$(ini_get ATOMHACKVER)
case "$ver" in
  *.custom_*)
    c=${ver##*.custom_}
    if git -C "$DIR" cat-file -e "$c^{commit}" 2> /dev/null; then
      pass "version: $ver ($(git -C "$DIR" log -1 --format=%s "$c" | sed "s:.* / ::" | cut -c1-60))"
    else
      fail "version: custom build commit" "$c of $ver is not in this repository"
    fi ;;
  *)
    skip "version: custom build commit" "$ver is not a custom build" ;;
esac
