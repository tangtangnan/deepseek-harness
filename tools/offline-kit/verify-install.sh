#!/usr/bin/env bash
# DeepSeek Harness 离线包 · 装机自检
#
# 证明「开箱即用」这件事：内置 Node 能跑、架构对得上、依赖树完整、
# 原生模块就位、pnpm 可用（dsh plugin 依赖它）、插件树与两个默认 subagent
# 插件已部署，最后实起一次 Web 服务。
#
# 用法：
#   bash verify-install.sh                      # 自动探测安装目录
#   bash verify-install.sh --prefix /data/dsh   # 指定安装目录（不要指向家目录！）
#   bash verify-install.sh --no-smoke           # 只做静态检查，不起服务
#   bash verify-install.sh --port 3081          # 冒烟用别的端口（默认 3080）
#
# 退出码：0 全部通过 / 2 只有警告（仍可用）/ 1 有致命项
set -uo pipefail

PREFIX="${DSH_PREFIX:-}"
NO_SMOKE=0
PORT=3080

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --no-smoke) NO_SMOKE=1; shift ;;
    --port) PORT="${2:-3080}"; shift 2 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    *) printf '未知参数：%s（用 --help 看用法）\n' "$1" >&2; exit 1 ;;
  esac
done

PASS=0; WARN=0; FAIL=0
ok()  { printf '  \033[32m✔\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
wn()  { printf '  \033[33m!\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
no()  { printf '  \033[31m✘\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
info(){ printf '  · %s\n' "$*"; }
say() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }

# ── ⓪ 定位安装目录 ────────────────────────────────────────────────────────
PREFIX="${PREFIX%/}"
if [ -z "$PREFIX" ]; then
  for c in "$HOME/.local/share/deepseek-harness" /opt/deepseek-harness "$PWD"; do
    [ -d "$c/runtime/bin" ] && PREFIX="$c" && break
  done
fi

if [ -z "$PREFIX" ] || [ ! -d "$PREFIX" ]; then
  printf '\n  \033[31m✘\033[0m 找不到安装目录。\n' >&2
  printf '    先安装：进入解压出来的包目录，执行  bash install.sh\n' >&2
  printf '    或指定路径：bash verify-install.sh --prefix <安装目录>\n' >&2
  for d in "$HOME"/deepseek-harness-*-offline-* "$HOME"/Downloads/deepseek-harness-*-offline-*; do
    [ -d "$d" ] && printf '    找到候选（解压目录，装完再验）：%s\n' "$d" >&2
  done
  exit 1
fi

# 误指家目录：这是最常见的手误（--prefix ~）
if [ -f "$PREFIX/.bashrc" ] || { [ -d "$PREFIX/.dsh" ] && [ ! -d "$PREFIX/runtime" ]; }; then
  printf '\n  \033[31m✘\033[0m %s 看起来是【家目录】，不是安装目录。\n' "$PREFIX" >&2
  printf '\n    正确顺序：\n' >&2
  printf '      1) cd <解压出来的包目录>      # 里面有 install.sh\n' >&2
  printf '      2) bash install.sh\n' >&2
  printf '      3) bash %s/verify-install.sh   # 不带 --prefix，自动探测\n\n' "$HOME/.local/share/deepseek-harness" >&2
  exit 1
fi

if [ ! -d "$PREFIX/runtime/bin" ] || [ ! -d "$PREFIX/kernel" ]; then
  printf '\n  \033[31m✘\033[0m %s 里没有 runtime/ 或 kernel/ —— 不是本包的安装目录（或还没装完）。\n' "$PREFIX" >&2
  printf '    装：bash <解压目录>/install.sh\n' >&2
  exit 1
fi

info "安装目录：$PREFIX"

# ── ① 结构 ────────────────────────────────────────────────────────────────
say "① 目录结构"
NODE="$PREFIX/runtime/bin/node"
BIN="$PREFIX/kernel/node_modules/@deepseek-ai/dsh/lib/bin.js"
[ -f "$NODE" ] && ok "runtime/bin/node 存在" || no "缺 runtime/bin/node"
[ -f "$BIN" ]  && ok "dsh 入口存在"          || no "缺 kernel/node_modules/@deepseek-ai/dsh/lib/bin.js"
if [ -x "$NODE" ]; then
  ok "node 有执行位"
elif [ -f "$NODE" ]; then
  no "node 存在但不可执行 —— 修复：chmod -R 0755 $PREFIX/runtime/bin"
else
  :
fi

# ── ② 内置 Node 能跑（且不依赖系统环境）───────────────────────────────────
say "② 内置 Node"
if [ -x "$NODE" ]; then
  V="$("$NODE" --version 2>&1 | tail -1)"
  case "$V" in
    v2[2-9]*|v[3-9][0-9]*) ok "node $V" ;;
    v*) wn "node $V（低于 22，dsh 可能不兼容）" ;;
    *) no "node --version 无输出：$V" ;;
  esac
  # 清空环境变量后仍能跑，才证明「不靠系统 Node」
  CV="$(env -i "$NODE" --version 2>&1 | tail -1)"
  [ -n "$CV" ] && ok "env -i 干净环境下仍可运行（$CV）" || no "干净环境下跑不起来（可能缺动态库）"
fi

# ── ③ 架构匹配 ────────────────────────────────────────────────────────────
say "③ 架构"
MACH="$(uname -m)"
ARCH_NODE="$(env PATH="$PREFIX/runtime/bin:$PATH" "$NODE" -p 'process.arch' 2>/dev/null || echo '?')"
case "$MACH:$ARCH_NODE" in
  x86_64:x64|aarch64:arm64) ok "系统 $MACH ↔ Node $ARCH_NODE" ;;
  *) no "架构不匹配：系统 $MACH，包里 Node 是 $ARCH_NODE（装错包了，换对应架构的 tar.gz）" ;;
esac

# ── ④ 依赖树与原生模块 ────────────────────────────────────────────────────
say "④ 依赖树"
NM="$PREFIX/kernel/node_modules"
if [ -d "$NM/@deepseek-ai" ]; then
  CNT="$(ls -1 "$NM/@deepseek-ai" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${CNT:-0}" -ge 100 ]; then ok "@deepseek-ai/* $CNT 个包"
  else wn "@deepseek-ai/* 只有 $CNT 个（依赖树可能不完整）"; fi
else
  no "缺 kernel/node_modules/@deepseek-ai"
fi
NA="$(ls -d "$NM"/@deepseek-ai/node-addon-system-* 2>/dev/null | head -1)"
[ -n "$NA" ] && ok "原生模块：$(basename "$NA")" || wn "未找到 node-addon-system-*（文件锁等能力降级）"
if [ -f "$NM/node-pty/build/Release/pty.node" ]; then
  ok "node-pty：build/Release/pty.node"
elif ls "$NM"/node-pty/prebuilds/*/pty.node >/dev/null 2>&1; then
  ok "node-pty：预编译 $(basename "$(ls -d "$NM"/node-pty/prebuilds/*/ 2>/dev/null | head -1)")"
else
  wn "node-pty 未产出 pty.node（内置终端可能不可用）"
fi

# ── ⑤ pnpm（dsh plugin 依赖）──────────────────────────────────────────────
say "⑤ pnpm（装插件用）"
PNPM="$PREFIX/runtime/bin/pnpm"
if [ -f "$PNPM" ]; then
  PV="$(env PATH="$PREFIX/runtime/bin:$PATH" "$PNPM" --version 2>/dev/null | tail -1)"
  case "$PV" in
    11.*) ok "pnpm $PV（dsh plugin 可用）" ;;
    "") wn "pnpm 存在但跑不起来 —— 用 $PREFIX/pnpm --version 再看；缺 node 在 PATH" ;;
    *) wn "pnpm $PV（包的内置版本是 11.x；12.x 含平台相关 exe，跨架构不可用）" ;;
  esac
else
  wn "未内置 pnpm —— dsh plugin / 离线装插件不可用（其余功能正常）"
  info "补装办法见包内 说明.md「离线安装插件」一节"
fi

# ── ⑥ 插件树 / 数据目录 / 启动器 ──────────────────────────────────────────
say "⑥ 数据与启动器"
DSH_HOME_DIR="${DSH_HOME:-$HOME/.dsh}"
if [ -d "$DSH_HOME_DIR/profiles" ]; then
  PS="$(ls -1 "$DSH_HOME_DIR/profiles" 2>/dev/null | tr '\n' ' ')"
  ok "profiles：$PS"
  for p in "$DSH_HOME_DIR"/profiles/*; do
    [ -d "$p" ] || continue
    if [ -d "$p/node_modules" ]; then
      info "$(basename "$p")：插件 $(ls -1 "$p/node_modules" 2>/dev/null | wc -l | tr -d ' ') 个"
    else
      wn "$(basename "$p")：没有 node_modules（插件可能未预装，首次启动会尝试联网）"
    fi
  done
else
  wn "$DSH_HOME_DIR/profiles 不存在（首次 dsh web 时会创建；离线环境将无法拉取 bundle）"
fi
# ── ⑥-b 默认预装的两个 subagent 插件 ─────────────────────────────────────
say "⑥-b 默认 subagent 插件"
WEB_PROFILE="$DSH_HOME_DIR/profiles/web"
if [ ! -f "$WEB_PROFILE/package.json" ] && [ -f "$PREFIX/home-template/profiles/web/package.json" ]; then
  wn "$DSH_HOME_DIR/profiles/web 还没部署，改查包内 home-template"
  WEB_PROFILE="$PREFIX/home-template/profiles/web"
fi
for p in "@deepseek-ai/dsh-subagent-codex" "@deepseek-ai/dsh-subagent-claude-code"; do
  if [ -f "$WEB_PROFILE/node_modules/$p/package.json" ]; then
    PV="$(grep -m1 '"version"' "$WEB_PROFILE/node_modules/$p/package.json" | sed 's/.*: *"//;s/".*//')"
    ok "$p（$PV）已落地"
  else
    wn "$p 未预装（本包可能是 --slim / --no-extra-plugins 构建的）"
  fi
done
if [ -f "$WEB_PROFILE/package.json" ] && [ -x "$NODE" ]; then
  MISS="$("$NODE" -e '
    const fs = require("fs");
    const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const deps = j.dependencies || {};
    const bundles = j.dsh?.profile?.bundles || [];
    const out = [];
    for (const n of process.argv.slice(2)) {
      if (!deps[n]) out.push(n + " 缺 dependencies");
      if (!bundles.includes(n)) out.push(n + " 缺 dsh.profile.bundles");
    }
    process.stdout.write(out.join("; "));
  ' "$WEB_PROFILE/package.json" \
     "@deepseek-ai/dsh-subagent-codex" "@deepseek-ai/dsh-subagent-claude-code" 2>/dev/null)"
  [ -z "$MISS" ] && ok "profile 清单：dependencies + bundles 两项齐全" \
                 || wn "profile 清单不全：$MISS（dsh 可能不会加载插件）"
fi

if [ -x "$HOME/.local/bin/dsh" ]; then
  ok "启动器：$HOME/.local/bin/dsh"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) wn "$HOME/.local/bin 不在 PATH —— 加：echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc" ;;
  esac
else
  wn "没有 ~/.local/bin/dsh（用了 --no-launcher？可直接用 $PREFIX/dsh）"
fi

# ── ⑦ 冒烟：实起一次 Web 服务 ────────────────────────────────────────────
say "⑦ 冒烟：启动 dsh web"
if [ "$NO_SMOKE" = "1" ]; then
  info "已按 --no-smoke 跳过"
elif [ "$FAIL" -gt 0 ]; then
  info "上面有致命项，跳过冒烟"
elif [ ! -x "$NODE" ] || [ ! -f "$BIN" ]; then
  info "缺少可执行文件，跳过冒烟"
else
  LOG="${TMPDIR:-/tmp}/dsh-verify-$$.log"
  env PATH="$PREFIX/runtime/bin:$PATH" DSH_HOME="$DSH_HOME_DIR" \
      "$NODE" "$BIN" web --no-open --port "$PORT" > "$LOG" 2>&1 &
  SPID=$!
  TOKEN_URL=""
  for i in $(seq 1 45); do
    TOKEN_URL="$(grep -o "http://127\.[0-9.]*:[0-9]\{2,5\}/?token=[A-Za-z0-9_-]\{20,\}" "$LOG" 2>/dev/null | head -1)"
    [ -n "$TOKEN_URL" ] && break
    kill -0 "$SPID" 2>/dev/null || break
    sleep 1
  done
  if [ -n "$TOKEN_URL" ]; then
    ok "服务已就绪（token URL 已生成）"
    if command -v curl >/dev/null 2>&1; then
      C="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 8 "$TOKEN_URL" 2>/dev/null)"
      case "$C" in
        200|303) ok "带 token 访问 → HTTP $C（跳转并下发会话 Cookie）" ;;
        000|"") wn "curl 无响应（代理？）" ;;
        *) wn "带 token 访问 → HTTP $C（预期 303）" ;;
      esac
    fi
    info "浏览器请打开：$TOKEN_URL"
    info "⚠ 用 Firefox 或 Chrome；国产安全浏览器（奇安信等）会导致「一直重新连接中」"
  else
    no "60 秒内没等到 token URL —— 服务没起来"
    tail -12 "$LOG" 2>/dev/null | sed 's/^/    /'
  fi
  kill "$SPID" 2>/dev/null || true
  wait "$SPID" 2>/dev/null || true
  rm -f "$LOG"
fi

# ── 结论 ──────────────────────────────────────────────────────────────────
printf '\n\033[1;36m▶ 结论\033[0m\n'
printf '  通过 %s 项 · 警告 %s 项 · 致命 %s 项\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '  \033[31m有致命项，这个安装不可用。\033[0m把上面的输出发出来（尤其带 ✘ 的行）。\n'
  exit 1
elif [ "$WARN" -gt 0 ]; then
  printf '  \033[33m基本可用，但有警告项。\033[0m多数情况不影响 Web UI 主流程。\n'
  printf '  下一步：dsh web --no-open，然后用 Firefox/Chrome 打开它打印的 ?token= URL\n'
  exit 2
else
  printf '  \033[32m开箱即用。\033[0m\n'
  printf '  下一步：dsh web --no-open，然后用 Firefox/Chrome 打开它打印的 ?token= URL\n'
  exit 0
fi
