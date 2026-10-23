# Hooks of the fork suite. Sourced by run.sh before the tests of every suite.
# fork スイートのフック（全スイートの実行前に run.sh が読み込む）

# A custom build (the version has .custom_<commit>) should have the fixes of the known
# issues, so count them as failures as with -k.
# カスタムビルドには既知の不具合の修正が入っているはずなので、-k と同じく失敗に数える
case "$(http /cgi-bin/hack_ini.cgi | sed -ne 's/^ATOMHACKVER=//p')" in
  *.custom_*) STRICT=1 ;;
esac

# ini_json : KEY=VALUE lines on stdin as the JSON the web UI sends to hack_ini.cgi and schedule.cgi
ini_json() {
  awk -F "=" '
    { k = $1; sub(/^[^=]*=/, ""); gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); printf("%s\"%s\":\"%s\"", n++ ? "," : "{", k, $0); }
    END { print "}"; }'
}

busy_meteor() { remote '/scripts/cmd meteor' | tr -d '\0' | grep -q '^recording ' && echo "meteor is recording"; }
BUSY_HOOKS="$BUSY_HOOKS busy_meteor"
