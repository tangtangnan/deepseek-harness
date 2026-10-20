#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# DeepSeek Harness —— 本地实验脚本（阶段一：联网环境验证）
#
# 干的事：在你手边**有网**的机器上，把官方 dsh 跑起来，确认「这个版本能用」，
#         再决定要不要打离线包。全程不碰系统目录、不需要 root。
#
#   dsh 是 Web UI 形态：`dsh web` 起服务（默认 127.0.0.1:3080），浏览器访问。
#   （与上一个 dsh-desktop 壳项目不同：这里不需要 Electron，也不需要编译原生模块，
#     原生模块是 per-arch 的预编译可选包 @deepseek-ai/node-addon-system-*，
#     npm 会自动按当前平台挑一个。）
#
# 用法：
#   bash experiment.sh                       # 装默认版本 + 启动 Web UI 冒烟后退出
#   bash experiment.sh --version 0.2.0-rc.2  # 指定版本
#   bash experiment.sh --port 3081 --keep    # 冒烟后保留服务进程（手动 kill 结束）
#   bash experiment.sh --from-source         # 从源码构建（慢：pnpm i + build，10~30 分钟）
#   bash experiment.sh --prefix /data/dshlab # 指定实验目录
#   bash experiment.sh --no-smoke            # 只装 + --version + 原生模块自检，不起服务
#
# 【关于 Web 冒烟的心智模型】
#   dsh 的 Web 服务**带 token 鉴权**：启动时打印
#     dsh web: http://127.0.0.1:3080/?token=<43 字符>
#   不带 token 直接 GET / 会回 **401**（这是设计，不是故障）。
#   所以判活不能用 curl -f（401 会被当成失败），本脚本改为：
#     ① 端口有任意 HTTP 响应（含 401）即视为已监听；
#     ② 再从日志里抓出那行 token URL，按真实访问路径探一次（预期 303）。
#   机器判活总是隔着一层，**最终还是你自己开浏览器看一眼最准**——
#   不想等就 --no-smoke，把验证留到真机上做。
#
# 环境变量：
#   DSH_VERSION=0.2.1-rc.2   默认安装版本
#   NPM_REGISTRY=...         默认 https://registry.npmmirror.com（失败自动回退 npmjs）
#   NODE_TOOLCHAIN_VER=v22.22.0   系统没 Node 时自动下载的独立 Node 版本
#   DSH_PORT=3080            冒烟用端口
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

DSH_VERSION="${DSH_VERSION:-0.2.1-rc.2}"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"
NPM_REGISTRY_FALLBACK="${NPM_REGISTRY_FALLBACK:-https://registry.npmjs.org}"
NODE_TOOLCHAIN_VER="${NODE_TOOLCHAIN_VER:-v22.22.0}"
DSH_PORT="${DSH_PORT:-3080}"

LAB="${LAB:-$HOME/.dsh-lab}"
FROM_SOURCE=0
KEEP=0
NO_SMOKE=0
SRC_REPO="${SRC_REPO:-https://github.com/deepseek-ai/deepseek-harness.git}"
SRC_REF="${SRC_REF:-master}"

while [ $# -gt 0 ]; do
  case "$1" in
    --version)      DSH_VERSION="$2"; shift 2 ;;
    --port)         DSH_PORT="$2"; shift 2 ;;
    --prefix)       LAB="$2"; shift 2 ;;
    --registry)     NPM_REGISTRY="$2"; shift 2 ;;
    --from-source)  FROM_SOURCE=1; shift ;;
    --keep)         KEEP=1; shift ;;
    --no-smoke)     NO_SMOKE=1; shift ;;
    -h|--help)      awk 'NR>2 && /^# ═/{exit} NR>2 {sub(/^# ?/,""); print}' "$0"; exit 0 ;;
    *) printf '未知参数: %s\n用法见: bash %s --help\n' "$1" "$0" >&2; exit 1 ;;
  esac
done

say()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  ✅ %s\n' "$*"; }
warn() { printf '  ⚠ %s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }
die()  { printf '\n  ✖ %b\n' "$*" >&2; exit 1; }

fetch() { # fetch <url> <dest>
  if command -v curl >/dev/null 2>&1; then
    curl -fSL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1"
  else
    return 127
  fi
}

# fetch_first <dest> <url1> <url2> ...：逐个尝试，第一个成功的落盘
fetch_first() {
  local dest="$1"; shift
  local u
  for u in "$@"; do
    info "尝试 $u"
    if fetch "$u" "$dest"; then return 0; fi
  done
  return 1
}

# 版本比较：ver_ge <a> <b> → a >= b 返回 0
ver_ge() {
  local a="${1#v}" b="${2#v}"
  [ "$(printf '%s\n%s\n' "$b" "$a" | sort -V | head -1)" = "$b" ]
}

# dsh 要求：node ^22.19.0 || >=24.0.0
node_ok() {
  local v major minor
  v="$(node --version 2>/dev/null)" || return 1
  v="${v#v}"
  major="${v%%.*}"
  minor="$(printf '%s' "$v" | cut -d. -f2)"
  case "$major" in
    22) [ "${minor:-0}" -ge 19 ] ;;
    24|25|26) return 0 ;;
    *) return 1 ;;
  esac
}

say "① 预检：环境"
printf '  · 实验目录 %s · 目标版本 %s\n' "$LAB" "$DSH_VERSION"
printf '  · 系统：%s %s\n' "$(uname -s)" "$(uname -m)"
command -v tar >/dev/null 2>&1 || die "缺少 tar"
if [ "$FROM_SOURCE" = "1" ]; then
  command -v git >/dev/null 2>&1 || die "--from-source 需要 git"
fi
ok "基础命令齐备"

# ── ② 准备 Node ───────────────────────────────────────────────────────────
say "② 准备 Node 运行时"
if node_ok; then
  ok "复用系统 Node $(node --version)"
  NODE_DIR="$(dirname "$(command -v node)")"
else
  warn "系统 Node 不满足要求（需 ^22.19.0 或 >=24），下载独立工具链 $NODE_TOOLCHAIN_VER"
  MACH="$(uname -m)"
  case "$MACH" in
    x86_64|amd64) NODE_ARCH_TC="x64" ;;
    aarch64|arm64) NODE_ARCH_TC="arm64" ;;
    *) die "未知 CPU 架构 $MACH：请自行安装 Node 22.19+ 或 24+ 后重跑" ;;
  esac
  case "$(uname -s)" in
    Linux)  TC_OS="linux" ;;
    Darwin) TC_OS="darwin" ;;
    *) die "非 Linux/macOS 系统，请自行安装 Node 22.19+ 或 24+ 后重跑" ;;
  esac
  TC_DIR="$LAB/toolchain"
  mkdir -p "$TC_DIR"
  NODE_TARBALL="node-$NODE_TOOLCHAIN_VER-$TC_OS-$NODE_ARCH_TC.tar.gz"
  fetch_first "$TC_DIR/node.tar.gz" \
    "https://npmmirror.com/mirrors/node/$NODE_TOOLCHAIN_VER/$NODE_TARBALL" \
    "https://nodejs.org/dist/$NODE_TOOLCHAIN_VER/$NODE_TARBALL" \
    || die "Node 工具链下载失败（两个源都不通）"
  tar -xzf "$TC_DIR/node.tar.gz" -C "$TC_DIR" || die "Node 工具链解压失败"
  rm -f "$TC_DIR/node.tar.gz"
  NODE_DIR="$TC_DIR/node-$NODE_TOOLCHAIN_VER-$TC_OS-$NODE_ARCH_TC/bin"
  [ -x "$NODE_DIR/node" ] || die "解压后找不到 node：$NODE_DIR/node"
  ok "独立工具链就绪：$(env PATH="$NODE_DIR:$PATH" node --version)"
fi
export PATH="$NODE_DIR:$PATH"
NPM="$(command -v npm)" || die "找不到 npm"

# ── ③ 安装 dsh ────────────────────────────────────────────────────────────
say "③ 安装 dsh"
APP="$LAB/app"
mkdir -p "$APP"

if [ "$FROM_SOURCE" = "1" ]; then
  SRC="$LAB/src"
  if [ ! -d "$SRC/.git" ]; then
    info "克隆源码 $SRC_REPO ($SRC_REF)"
    git clone --depth 1 -b "$SRC_REF" "$SRC_REPO" "$SRC" || die "源码克隆失败"
  fi
  cd "$SRC" || die "进入源码目录失败"
  if ! command -v pnpm >/dev/null 2>&1; then
    info "未找到 pnpm，尝试 corepack 启用"
    corepack enable >/dev/null 2>&1 || true
    corepack prepare pnpm@11.28.5 --activate >/dev/null 2>&1 \
      || npm i -g pnpm@11.28.5 >/dev/null 2>&1 \
      || die "需要 pnpm 11（仓库 packageManager 指定）。请手动安装后重跑。"
  fi
  info "pnpm install（首次较慢）"
  pnpm install --registry "$NPM_REGISTRY" || die "pnpm install 失败"
  info "pnpm build"
  pnpm run build || die "pnpm build 失败"
  DSH_BIN="$SRC/apps/cli/src/bin.ts"
  RUNNER=(env PATH="$NODE_DIR:$PATH" node --import tsx/esm "$DSH_BIN")
  VERSION_OUT="source@$SRC_REF"
else
  printf '{"name":"dsh-lab","private":true,"version":"1.0.0"}\n' > "$APP/package.json"
  info "npm install @deepseek-ai/dsh@$DSH_VERSION"
  if ! npm install --prefix "$APP" "@deepseek-ai/dsh@$DSH_VERSION" \
        --registry "$NPM_REGISTRY" --no-audit --fund=false 2>&1 | tail -5; then
    warn "主 registry 失败，回退 $NPM_REGISTRY_FALLBACK"
    npm install --prefix "$APP" "@deepseek-ai/dsh@$DSH_VERSION" \
        --registry "$NPM_REGISTRY_FALLBACK" --no-audit --fund=false \
      || die "dsh 安装失败（两个源都不可达，或版本号不存在）"
  fi
  [ -f "$APP/node_modules/@deepseek-ai/dsh/lib/bin.js" ] \
    || die "安装后缺少 lib/bin.js：$APP/node_modules/@deepseek-ai/dsh/lib/bin.js"
  DSH_BIN="$APP/node_modules/@deepseek-ai/dsh/lib/bin.js"
  RUNNER=(env PATH="$NODE_DIR:$PATH" node "$DSH_BIN")
  PKG_COUNT="$(ls -1 "$APP/node_modules/@deepseek-ai" 2>/dev/null | wc -l | tr -d ' ')"
  ok "dsh 已安装（@deepseek-ai/* 共 $PKG_COUNT 个包）"
  VERSION_OUT="$("${RUNNER[@]}" --version 2>&1 | head -1)"
fi
ok "版本：$VERSION_OUT"

# 原生模块自检（per-arch 预编译可选包）
NA_DIR="$(ls -d "$APP"/node_modules/@deepseek-ai/node-addon-system-* 2>/dev/null | head -1)"
if [ -n "$NA_DIR" ]; then
  ok "原生模块已就位：$(basename "$NA_DIR")"
else
  warn "未找到原生模块 @deepseek-ai/node-addon-system-*（文件锁/landlock 相关能力可能降级，Web UI 通常仍可启动）"
fi

# 取 HTTP 状态码：连不上/超时/无 curl 都返回 000
http_code() {
  local c=""
  if command -v curl >/dev/null 2>&1; then
    c="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$1" 2>/dev/null)" || c=""
  elif command -v wget >/dev/null 2>&1; then
    c="$(wget -q -S -O /dev/null -T 5 "$1" 2>&1 \
          | grep -o 'HTTP/[0-9.]* [0-9]\{3\}' | tail -1 | awk '{print $2}')" || c=""
  fi
  case "$c" in
    [1-9]*) printf '%s' "$c" ;;
    *) printf '000' ;;
  esac
}

# ── ④ 冒烟：启动 Web UI ───────────────────────────────────────────────────
READY=0
UP_CODE=000
if [ "$NO_SMOKE" = "1" ]; then
  say "④ 跳过 Web 冒烟（--no-smoke）"
  info "已验证：安装 / 版本 / 原生模块。服务能否打开留到目标机上用浏览器确认"
  echo "SMOKE=SKIP"
else
  say "④ 冒烟：启动 dsh web（端口 $DSH_PORT）"
  LOG="$LAB/web.log"
  mkdir -p "$LAB"
  info "命令：${RUNNER[*]} web --no-open --port $DSH_PORT"
  "${RUNNER[@]}" web --no-open --port "$DSH_PORT" > "$LOG" 2>&1 &
  SRV_PID=$!
  trap 'kill $SRV_PID 2>/dev/null || true' EXIT

  # 等就绪：优先等 dsh 打印的 ready URL（含 token，打印即表示已监听），
  # 同时兼探端口——注意 401 也算活着，那是 dsh 的 token 鉴权在正常工作。
  TOKEN_URL=""
  UP_CODE=000
  for i in $(seq 1 30); do
    if [ -z "$TOKEN_URL" ]; then
      TOKEN_URL="$(grep -o "http://127\.0\.0\.1:[0-9]\{2,5\}/?token=[A-Za-z0-9_-]\{20,\}" \
                    "$LOG" 2>/dev/null | head -1)"
    fi
    [ -n "$TOKEN_URL" ] && break
    UP_CODE="$(http_code "http://127.0.0.1:$DSH_PORT/")"
    [ "$UP_CODE" != "000" ] && break
    kill -0 "$SRV_PID" 2>/dev/null || break
    sleep 2
  done

  READY=0
  if [ "$UP_CODE" != "000" ]; then
    READY=1
    ok "端口已监听（HTTP $UP_CODE；401 = 缺 token，属正常鉴权响应）"
  fi
  if [ -n "$TOKEN_URL" ]; then
    info "服务自报地址：$TOKEN_URL"
    TCODE="$(http_code "$TOKEN_URL")"
    case "$TCODE" in
      200|303)
        ok "带 token 访问正常（HTTP $TCODE，已下发会话 Cookie）"
        READY=1
        [ "$UP_CODE" = "000" ] && UP_CODE="$TCODE"
        ;;
      *) warn "带 token 访问返回 HTTP $TCODE（预期 303 或 200）" ;;
    esac
  else
    warn "日志里没抓到 dsh 打印的 ready URL（含 token）"
  fi

  if [ "$READY" = "1" ]; then
    info "首次使用需在页面上配置 DeepSeek API Key（这是产品逻辑，与离线包无关）"
  else
    warn "Web 服务未能在预期时间内就绪。日志尾部："
    tail -25 "$LOG" 2>/dev/null | sed 's/^/    /'
    warn "可能原因：① 启动更慢（加 --keep 后台跑，自己盯日志）② 端口被占（换 --port）③ 启动报错（看上面日志）"
  fi
  echo "SMOKE=$READY"

  if [ "$KEEP" = "1" ]; then
    trap - EXIT
    ok "已按 --keep 保留服务进程（PID $SRV_PID），日志：$LOG"
    [ -n "$TOKEN_URL" ] && info "浏览器打开：$TOKEN_URL"
    info "结束服务：kill $SRV_PID"
    exit 0
  fi
fi

# ── ⑤ 结论 ────────────────────────────────────────────────────────────────
say "⑤ 实验结论"
if [ "$NO_SMOKE" = "1" ]; then
  SMOKE_TXT="未做（--no-smoke）：服务能否打开留到目标机验证"
elif [ "$READY" = "1" ]; then
  SMOKE_TXT="服务已起（HTTP $UP_CODE）"
else
  SMOKE_TXT="未在预期时间内就绪 —— 不代表装错了，也可能是启动慢"
fi
cat <<TIP

  版本      : $VERSION_OUT
  安装方式  : $([ "$FROM_SOURCE" = "1" ] && echo '源码构建' || echo "npm 包 @deepseek-ai/dsh@$DSH_VERSION")
  实验目录  : $LAB
  Node      : $(node --version)  ($NODE_DIR)
  Web 冒烟  : $SMOKE_TXT

  装得上、原生模块对，就可以进入阶段二：
  在**与目标机同架构**的联网机器上执行 build-offline.sh 打离线包，
  再把 tar.gz 拷到断网机器安装。

  离线包构建：
    bash build-offline.sh --arch arm64      # 生产机是 arm64
    bash build-offline.sh --arch amd64      # 生产机是 x86_64
  （也可以直接用 workflows/ 里的 GitHub Actions 云构建，见 README）

TIP
ok "实验流程结束"
