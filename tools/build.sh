#!/usr/bin/env bash
# Checks and builds the unsigned HAP: unit tests, TDLib request check, hvigor.
#   tools/build.sh [debug|release]
# Needs JAVA_HOME (Java 17) or a JRE under ~/ohos-build/jdk, and local.properties.
set -uo pipefail
cd "$(dirname "$0")/.."
mode="${1:-release}"
if [ -z "${JAVA_HOME:-}" ]; then
  JAVA_HOME="$(ls -d "$HOME"/ohos-build/jdk/jdk-17*/ 2>/dev/null | head -1)"
  export JAVA_HOME
fi
export PATH="$JAVA_HOME/bin:$PATH"
if [ -z "${OHOS_BASE_SDK_HOME:-}" ]; then
  OHOS_BASE_SDK_HOME="$(sed -n 's/^sdk\.dir=//p' local.properties)"
  export OHOS_BASE_SDK_HOME
fi

node tools/test.mjs > /tmp/tdgram-test.log 2>&1 || { grep -E '^✖|^not ok|Error|expected|actual' /tmp/tdgram-test.log | head -40; echo "unit tests FAILED"; exit 1; }
grep -E '^ℹ (pass|fail)' /tmp/tdgram-test.log | tr '\n' ' '; echo
node tools/check-td.mjs || exit 1

log=/tmp/tdgram-build.log
node node_modules/@ohos/hvigor/bin/hvigor.js --mode module -p module=entry@default -p product=default \
  -p buildMode="$mode" assembleHap --no-daemon > "$log" 2>&1
status=$?
clean() { sed 's/\x1b\[[0-9;]*m//g' "$log"; }
# ArkTS errors with their messages; the known "native module is not verified" warnings are skipped.
clean | awk '/ArkTS:ERROR/ {show=5} /ArkTS:WARN/ {show = ($0 ~ /\.ets:[0-9]+:[0-9]+$/) ? 3 : 0} show > 0 {print; show--}' \
  | grep -v -B1 -A1 "is not verified" | grep -v '^--$' | head -150
clean | grep -E "COMPILE RESULT|BUILD (SUCCESSFUL|FAILED)|hvigor ERROR" | grep -v "ArkTS Compiler Error" | head -8
exit $status
