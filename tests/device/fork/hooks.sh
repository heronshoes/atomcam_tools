# Hooks of the fork suite. Sourced by run.sh before the tests of every suite.
# fork スイートのフック（全スイートの実行前に run.sh が読み込む）

# ini_json : KEY=VALUE lines on stdin as the JSON the web UI sends to hack_ini.cgi and schedule.cgi
ini_json() {
  awk -F "=" '
    { k = $1; sub(/^[^=]*=/, ""); gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); printf("%s\"%s\":\"%s\"", n++ ? "," : "{", k, $0); }
    END { print "}"; }'
}
