#!/usr/bin/env bash
# 自测：验证本包自带的 test_runner.sh 对四种情况判断正确。
# 这是"测测试"（test the test）：通过 / 非零退出 / 只打错误日志 / 挂死。
set -uo pipefail
cd "$(dirname "$0")/.."

RUNNER="skills/verification/templates/test_runner.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf '#!/usr/bin/env bash\necho "全部通过"\nexit 0\n' >"$TMP/ok.sh"
printf '#!/usr/bin/env bash\necho "断言失败：期望 0.15，实际 0.42"\nexit 1\n' >"$TMP/fail.sh"
printf '#!/usr/bin/env bash\necho "Run"\necho "ERROR: something broke"\nexit 0\n' >"$TMP/err.sh"
printf '#!/usr/bin/env bash\necho "开始"\nsleep 30\n' >"$TMP/hang.sh"
chmod +x "$TMP"/*.sh

echo "▶ 自测 test_runner.sh（超时 3s）"
out="$(TIMEOUT=3 bash "$RUNNER" \
  "正常通过|$TMP/ok.sh" \
  "非零退出|$TMP/fail.sh" \
  "只打错误日志|$TMP/err.sh" \
  "挂死不退出|$TMP/hang.sh" 2>&1)"
code=$?
echo "$out"
echo ""

fail=0
check() { # $1=名称 $2=期望 passed|failed
  local line
  line="$(echo "$out" | grep -F "$1" | head -1)"
  if [ "$2" = "passed" ]; then
    case "$line" in "  ✓"*) printf '  ✓ 判定正确：%s\n' "$1" ;; *) printf '  ✗ 应判通过：%s\n' "$1"; fail=1 ;; esac
  else
    case "$line" in "  ✗"*) printf '  ✓ 判定正确：%s\n' "$1" ;; *) printf '  ✗ 应判失败：%s\n' "$1"; fail=1 ;; esac
  fi
}
check "正常通过" passed
check "非零退出" failed
check "只打错误日志" failed
check "挂死不退出" failed

if [ "$code" -eq 0 ]; then
  echo "  ✗ runner 退出码应为 1，实际 0"
  fail=1
fi

echo ""
if [ "$fail" -eq 0 ]; then
  echo "✅ 自测通过：runner 对四种情况判断正确"
  exit 0
fi
echo "❌ 自测失败"
exit 1
