#!/usr/bin/env bash
# test_runner.sh —— 语言/框架无关的测试执行器
#
# 解决三件事：收集退出码、grep 错误模式（防止框架吞掉错误）、检测挂死（不退出）。
#
# 用法一（命令行直接给）：按 "名称|命令" 传参
#   ./test_runner.sh "unit|pytest -q tests/unit" "e2e|npm run e2e"
#
# 用法二（从文件读）：每行 "名称|命令"，空行和 # 注释会被忽略
#   ./test_runner.sh -f targets.txt
#
# 环境变量：
#   TIMEOUT=180          单个用例超时秒数（默认 180）
#   ERR_PATTERN="..."    替换默认错误模式（grep -E）。设空字符串可关闭检查
#                        默认含 ^ERROR:/^error:/^Error: —— 很多工具（如 Godot）
#                        打错误日志但退出码仍是 0，不 grep 就会假通过。
#                        若某个用例"预期会报错"，为它单独设 ERR_PATTERN。
#   QUIET=1              只打印失败用例
#
# 退出码：全部通过 0；有用例失败 1。
set -uo pipefail

TIMEOUT="${TIMEOUT:-180}"
QUIET="${QUIET:-0}"
DEFAULT_ERR='^ERROR[: ]|^error[: ]|^Error[: ]|SCRIPT ERROR|Traceback \(most recent call last\)|panicked at|FATAL|Exception in thread|Unhandled exception|Segmentation fault|core dumped|AssertionError'
if [ "${ERR_PATTERN+set}" = set ]; then
  ERRS="$ERR_PATTERN"
else
  ERRS="$DEFAULT_ERR"
fi

total=0
failed=0
declare -a failures=()

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

# 运行单个用例：$1 名称，$2 命令
run_one() {
  local name="$1" cmd="$2"
  total=$((total + 1))
  local log
  log="$(mktemp -t testrunner.XXXXXX)"

  # 后台启动，自己轮询超时（macOS 没有 coreutils 的 timeout）
  bash -c "$cmd" >"$log" 2>&1 &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$TIMEOUT" ]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      printf '  ✗ %-30s TIMEOUT（>%ss，进程未自行退出 / 疑似挂死）\n' "$name" "$TIMEOUT"
      sed -n '1,6p' "$log" | sed 's/^/        /'
      failures+=("$name [timeout]")
      failed=$((failed + 1))
      rm -f "$log"
      return
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
  local code=$?

  # 错误模式检查：框架可能把错误打成日志却不改退出码
  local hits=0
  if [ -n "$ERRS" ]; then
    hits=$(grep -cE "$ERRS" "$log" 2>/dev/null || true)
    hits="${hits:-0}"
  fi

  if [ "$code" -eq 0 ] && [ "$hits" -eq 0 ]; then
    [ "$QUIET" = "1" ] || printf '  ✓ %-30s exit=0，无错误模式命中\n' "$name"
  else
    printf '  ✗ %-30s exit=%s，错误模式命中 %s 次\n' "$name" "$code" "$hits"
    if [ "$hits" -gt 0 ]; then
      grep -E "$ERRS" "$log" 2>/dev/null | head -5 | sed 's/^/        /'
    else
      tail -6 "$log" | sed 's/^/        /'
    fi
    failures+=("$name [exit=$code, errors=$hits]")
    failed=$((failed + 1))
  fi
  rm -f "$log"
}

# 解析参数
if [ "$#" -eq 0 ]; then usage; fi
declare -a specs=()
if [ "$1" = "-f" ]; then
  [ -f "${2:-}" ] || { echo "找不到目标文件：${2:-}"; exit 2; }
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    specs+=("$line")
  done <"$2"
else
  specs=("$@")
fi

echo "▶ 运行 ${#specs[@]} 个用例（超时 ${TIMEOUT}s）"
echo ""
for spec in "${specs[@]}"; do
  if [[ "$spec" != *"|"* ]]; then
    printf '  ✗ 跳过格式错误的条目（需要 "名称|命令"）：%s\n' "$spec"
    failed=$((failed + 1))
    total=$((total + 1))
    failures+=("$spec [格式错误]")
    continue
  fi
  run_one "${spec%%|*}" "${spec#*|}"
done

echo ""
if [ "$failed" -eq 0 ]; then
  echo "🎉 全部 ${total} 个用例通过"
  exit 0
fi
echo "💥 ${failed}/${total} 个用例失败："
for f in "${failures[@]}"; do echo "   · $f"; done
exit 1
