#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# DeepSeek Harness —— 全离线便携包构建脚本（阶段二：实验通过后）
#
# 产出一个免 root 的 tar.gz：内置 Node 运行时 + dsh 完整依赖树 + 预装的
# profile 插件。拷到断网机器解压 → bash install.sh → `dsh web` 即用，
# 全程零联网、零 npm、零 sudo。
#
# 【为什么必须在「与目标机同架构」的联网机器上构建】
#   dsh 依赖里有 node-pty（虽有 linux-x64 / linux-arm64 预编译包，但由
#   install 脚本按当前平台挑选并解包）和 @deepseek-ai/node-addon-system-*
#   （npm optional dep，按 os/cpu 自动筛选）。所以：
#     · 生产机 arm64 → 在 arm64 机器上构建（GitHub 的 ubuntu-24.04-arm 免费）
#     · 生产机 x86_64 → 在任意 x86_64 Linux 上构建
#   交叉构建不保证原生模块可用（可用 --cpu/--os 勉强尝试，但不推荐）。
#
# 用法：
#   bash build-offline.sh                  # 按当前机器架构构建
#   bash build-offline.sh --arch arm64     # 显式指定（不匹配会直接中止）
#   bash build-offline.sh --version 0.2.0-rc.2
#   bash build-offline.sh --slim           # 不预装 profile 插件（包小 ~300MB，
#                                          # 但离线机每次启动会尝试联网拉插件后跳过）
#
# 环境变量：
#   DSH_VERSION=0.2.1-rc.2
#   NODE_RUNTIME_VER=v22.22.0       内置 Node 版本（满足 engines: ^22.19 || >=24）
#   NPM_REGISTRY / NPM_REGISTRY_FALLBACK
#   WORK=<构建工作目录>  OUT=<产物目录>
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

DSH_VERSION="${DSH_VERSION:-0.2.1-rc.2}"
NODE_RUNTIME_VER="${NODE_RUNTIME_VER:-v22.22.0}"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"
NPM_REGISTRY_FALLBACK="${NPM_REGISTRY_FALLBACK:-https://registry.npmjs.org}"
NODE_MIRROR="${NODE_MIRROR:-https://npmmirror.com/mirrors/node}"

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$KIT_DIR/build}"
OUT="${OUT:-$KIT_DIR/release}"

ARCH_INPUT="auto"
SLIM=0
while [ $# -gt 0 ]; do
  case "$1" in
    --arch)    ARCH_INPUT="$2"; shift 2 ;;
    --version) DSH_VERSION="$2"; shift 2 ;;
    --registry) NPM_REGISTRY="$2"; shift 2 ;;
    --work)    WORK="$2"; shift 2 ;;
    --out)     OUT="$2"; shift 2 ;;
    --slim)    SLIM=1; shift ;;
    -h|--help) awk 'NR>2 && /^# ═/{exit} NR>2 {sub(/^# ?/,""); print}' "$0"; exit 0 ;;
    *) printf '未知参数: %s\n' "$1" >&2; exit 1 ;;
  esac
done

say()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  ✅ %s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }
warn() { printf '  ⚠ %s\n' "$*"; }
die()  { printf '\n  ✖ %b\n' "$*" >&2; exit 1; }

fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fSL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1"
  else
    return 127
  fi
}
fetch_first() {
  local dest="$1"; shift
  local u
  for u in "$@"; do
    info "尝试 $u"
    if fetch "$u" "$dest"; then return 0; fi
  done
  return 1
}

# ── ① 预检 ────────────────────────────────────────────────────────────────
say "① 预检"
case "$(uname -s)" in
  Linux) ;;
  *) die "离线包必须在 Linux 上构建（当前：$(uname -s)）。
  打出来的包里 Node / node-pty 都是 Linux 二进制，在别的系统上构建会产出跑不起来的包。
  Windows / macOS 用户请改用 workflows/package-offline-multi-arch.yml 云构建。" ;;
esac
HOST_MACH="$(uname -m)"
case "$HOST_MACH" in
  x86_64|amd64) HOST_ARCH="amd64" ;;
  aarch64|arm64) HOST_ARCH="arm64" ;;
  *) HOST_ARCH="unknown" ;;
esac
case "$ARCH_INPUT" in
  amd64) WANT_HOST="x86_64"; NODE_ARCH="x64";   ARCH_LABEL="x86_64 (amd64)" ;;
  arm64) WANT_HOST="aarch64"; NODE_ARCH="arm64"; ARCH_LABEL="aarch64 (arm64)" ;;
  auto)
    [ "$HOST_ARCH" != "unknown" ] || die "无法识别本机架构 $(uname -m)，请用 --arch amd64|arm64 指定"
    case "$HOST_ARCH" in
      amd64) WANT_HOST="x86_64"; NODE_ARCH="x64";   ARCH_LABEL="x86_64 (amd64)" ;;
      arm64) WANT_HOST="aarch64"; NODE_ARCH="arm64"; ARCH_LABEL="aarch64 (arm64)" ;;
    esac
    ;;
  *) die "--arch 只支持 amd64|arm64|auto，收到：$ARCH_INPUT" ;;
esac
ARCH="$ARCH_INPUT"
[ "$ARCH" = "auto" ] && ARCH="$HOST_ARCH"

[ "$HOST_MACH" = "$WANT_HOST" ] || die "架构不匹配：本机 $HOST_MACH，目标 $ARCH_LABEL。
dsh 依赖的原生模块（node-pty 预编译包、@deepseek-ai/node-addon-system-*）
按当前平台解包/筛选，**无法跨架构构建**。
  构建 arm64 包 → 请在 aarch64 机器上跑（或直接用 GitHub 的 ubuntu-24.04-arm runner）
  构建 amd64 包 → 请在 x86_64 机器上跑"

for c in tar gzip sha256sum sed grep awk; do
  command -v "$c" >/dev/null 2>&1 || die "缺少命令: $c"
done
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || die "缺少 curl 或 wget"
command -v node >/dev/null 2>&1 || die "构建机需要 Node（任意 18+ 即可，仅用于构建；打包进去的是独立下载的运行时）"
command -v npm  >/dev/null 2>&1 || die "构建机需要 npm"
ok "架构 $ARCH_LABEL，基础工具齐备（dsh $DSH_VERSION）"

rm -rf "$WORK"
STAGE="$WORK/stage"
APP="$STAGE/deepseek-harness-$DSH_VERSION-$ARCH"
mkdir -p "$APP" "$OUT"

# ── ② 下载目标架构的 Node 运行时 ──────────────────────────────────────────
say "② 下载 Node $NODE_RUNTIME_VER（linux-$NODE_ARCH）"
RT_DIR="$APP/runtime"
mkdir -p "$RT_DIR"
# .tar.xz 更小，但依赖 xz 命令（精简系统可能没有）——缺 xz 就直接用 .tar.gz
# 已存在则复用（重跑时省一次 50MB 下载）
TGZ="node-$NODE_RUNTIME_VER-linux-$NODE_ARCH.tar.gz"
XZ="node-$NODE_RUNTIME_VER-linux-$NODE_ARCH.tar.xz"
USE_XZ=""
[ -s "$WORK/node.tar.xz" ] && USE_XZ="xz"
[ -s "$WORK/node.tar.gz" ] && USE_XZ="gz"
if [ -z "$USE_XZ" ]; then
  if command -v xz >/dev/null 2>&1; then
    fetch_first "$WORK/node.tar.xz" \
      "$NODE_MIRROR/$NODE_RUNTIME_VER/$XZ" \
      "https://nodejs.org/dist/$NODE_RUNTIME_VER/$XZ" && USE_XZ="xz"
  fi
  if [ -z "$USE_XZ" ]; then
    command -v xz >/dev/null 2>&1 || info "本机无 xz 命令，改用 .tar.gz"
    fetch_first "$WORK/node.tar.gz" \
      "$NODE_MIRROR/$NODE_RUNTIME_VER/$TGZ" \
      "https://nodejs.org/dist/$NODE_RUNTIME_VER/$TGZ" \
      || die "Node 运行时下载失败（两个源都不通）"
    USE_XZ="gz"
  fi
fi
if [ "$USE_XZ" = "xz" ]; then
  tar -xJf "$WORK/node.tar.xz" -C "$RT_DIR" --strip-components=1 || die "Node 解压失败（.tar.xz）"
else
  tar -xzf "$WORK/node.tar.gz" -C "$RT_DIR" --strip-components=1 || die "Node 解压失败（.tar.gz）"
fi
# 显式补执行位：部分环境下 tar 解压后 mode 会丢（尤其跨文件系统拷贝时）
chmod 0755 "$RT_DIR"/bin/node 2>/dev/null || true
chmod 0755 "$RT_DIR"/bin/npm "$RT_DIR"/bin/npx 2>/dev/null || true
[ -f "$RT_DIR/bin/node" ] || die "解压后找不到 $RT_DIR/bin/node"
ok "Node 运行时已就位（$NODE_RUNTIME_VER linux-$NODE_ARCH）"

# ── ③ 安装 dsh 依赖树 ─────────────────────────────────────────────────────
say "③ 安装 dsh 依赖树（npm，约 5~15 分钟）"
KERNEL="$APP/kernel"
mkdir -p "$KERNEL"
printf '{"name":"dsh-offline","private":true,"version":"1.0.0"}\n' > "$KERNEL/package.json"
export PATH="$RT_DIR/bin:$PATH"          # 用内置 Node 跑 npm，原生模块 ABI 一致
info "npm install @deepseek-ai/dsh@$DSH_VERSION --registry $NPM_REGISTRY"
if ! npm install --prefix "$KERNEL" "@deepseek-ai/dsh@$DSH_VERSION" \
      --registry "$NPM_REGISTRY" --no-audit --fund=false 2>&1 | tail -6; then
  warn "主 registry 失败，回退 $NPM_REGISTRY_FALLBACK"
  npm install --prefix "$KERNEL" "@deepseek-ai/dsh@$DSH_VERSION" \
      --registry "$NPM_REGISTRY_FALLBACK" --no-audit --fund=false \
    || die "dsh 安装失败（两个源都不可达）"
fi
[ -f "$KERNEL/node_modules/@deepseek-ai/dsh/lib/bin.js" ] \
  || die "缺少 lib/bin.js：$KERNEL/node_modules/@deepseek-ai/dsh/lib/bin.js"
ok "依赖树就位（@deepseek-ai/* $(ls -1 "$KERNEL/node_modules/@deepseek-ai" | wc -l | tr -d ' ') 个包）"

# 原生模块自检
NA="$(ls -d "$KERNEL"/node_modules/@deepseek-ai/node-addon-system-* 2>/dev/null | head -1)"
if [ -n "$NA" ]; then
  ok "原生模块：$(basename "$NA")"
else
  warn "未找到 @deepseek-ai/node-addon-system-*（文件锁/landlock 能力降级，Web UI 通常仍可用）"
fi
PTY="$(ls "$KERNEL"/node_modules/node-pty/prebuilds/*/pty.node 2>/dev/null | head -1)"
if [ -f "$KERNEL/node_modules/node-pty/build/Release/pty.node" ]; then
  ok "node-pty 已解包：build/Release/pty.node"
elif [ -n "$PTY" ]; then
  ok "node-pty 预编译包：${PTY#$KERNEL/node_modules/node-pty/}"
else
  warn "node-pty 未产出 pty.node —— 内置终端功能可能不可用（构建机缺 build-essential/python3？）"
fi

# ── ④ 预装 profile 插件（可选）────────────────────────────────────────────
HOME_TPL="$APP/home-template"
if [ "$SLIM" = "1" ]; then
  say "④ 跳过 profile 插件预装（--slim）"
  mkdir -p "$HOME_TPL"
  warn "离线机首次启动会尝试联网拉取 profile bundle，失败后跳过（Web UI 主体不受影响）"
else
  say "④ 预装 profile 插件（首次启动联网拉取的那批，约 3~10 分钟）"
  # dsh 用 pnpm 在 $DSH_HOME/profiles/<profile>/ 下装 bundle；这里起一次 web 让它装完，
  # 再把结果打包带走。装完后再启动就不需要网络了。
  if ! command -v pnpm >/dev/null 2>&1; then
    info "准备 pnpm（dsh 用它安装 profile 插件）"
    corepack enable >/dev/null 2>&1 || true
    corepack prepare pnpm@11.28.5 --activate >/dev/null 2>&1 \
      || npm i -g pnpm@11.28.5 --registry "$NPM_REGISTRY" >/dev/null 2>&1 \
      || warn "pnpm 不可用 —— 插件预装可能失败，将回退为不预装（--slim 等价）"
  fi
  TMP_HOME="$WORK/home-seed"
  rm -rf "$TMP_HOME"; mkdir -p "$TMP_HOME"
  LOG="$WORK/seed-web.log"
  DSH_BIN="$KERNEL/node_modules/@deepseek-ai/dsh/lib/bin.js"
  SEED_PORT="${SEED_PORT:-3080}"
  info "启动一次 dsh web（端口 $SEED_PORT，仅用于触发插件安装）"
  env PATH="$RT_DIR/bin:$PATH" DSH_HOME="$TMP_HOME" \
      npm_config_registry="$NPM_REGISTRY" \
      "$RT_DIR/bin/node" "$DSH_BIN" web --no-open --port "$SEED_PORT" > "$LOG" 2>&1 &
  SEED_PID=$!
  # 判活：等日志里出现 dsh 打印的「dsh web: http://.../?token=...」。
  # 不能直接 curl -sf 探 / —— dsh 对不带 token 的 GET / 回 401（鉴权设计），会误判成没起来。
  READY=0
  for i in $(seq 1 40); do
    if grep -q "dsh web: http" "$LOG" 2>/dev/null; then READY=1; break; fi
    kill -0 "$SEED_PID" 2>/dev/null || break
    sleep 3
  done
  # 起来后再给插件安装一点时间：等 profiles/web 真正出现（最多再 5 分钟）
  if [ "$READY" = "1" ]; then
    for i in $(seq 1 60); do
      [ -d "$TMP_HOME/profiles/web" ] && break
      kill -0 "$SEED_PID" 2>/dev/null || break
      sleep 5
    done
  fi
  kill "$SEED_PID" 2>/dev/null || true
  wait "$SEED_PID" 2>/dev/null || true

  if [ -d "$TMP_HOME/profiles" ] && [ -d "$TMP_HOME/profiles/web" ]; then
    mkdir -p "$HOME_TPL"
    cp -a "$TMP_HOME/profiles" "$HOME_TPL/" || warn "复制 profiles 失败"
    ok "profile 插件已预装（profiles/web）"
    # 清理与机器/用户绑定的东西，只留可复用的插件树
    rm -rf "$HOME_TPL/profiles/"*/sessions "$HOME_TPL/profiles/"*/storages 2>/dev/null || true
    find "$HOME_TPL" -name "*.log" -delete 2>/dev/null || true
  else
    warn "插件预装未完成（pnpm 缺失或网络问题）—— 将按 --slim 方式打包"
    mkdir -p "$HOME_TPL"
  fi
  if [ "$READY" != "1" ]; then
    info "种子启动未检测到端口就绪，日志尾部："
    tail -15 "$LOG" 2>/dev/null | sed 's/^/    /'
  fi
fi

# ── ⑤ 生成启动器 / 安装卸载脚本 ───────────────────────────────────────────
say "⑤ 生成启动器与安装脚本"

# 包内直启脚本（免安装也能用）
cat > "$APP/dsh" <<'EOF'
#!/usr/bin/env bash
# 包内直启：不安装也能跑（数据落在 ./home，卸载即删）
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HERE/runtime/bin:$PATH"
export DSH_HOME="${DSH_HOME:-$HERE/home}"
exec "$HERE/runtime/bin/node" "$HERE/kernel/node_modules/@deepseek-ai/dsh/lib/bin.js" "$@"
EOF
chmod 0755 "$APP/dsh"

cat > "$APP/install.sh" <<'EOF'
#!/usr/bin/env bash
# DeepSeek Harness 离线包安装（普通权限即可，不需要 root / sudo）
set -uo pipefail

PREFIX="${DSH_PREFIX:-$HOME/.local/share/deepseek-harness}"
NO_LAUNCHER=0
HOME_MODE=copy        # copy: 插件树拷进 ~/.dsh（默认）
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)    PREFIX="$2"; shift 2 ;;
    --no-launcher) NO_LAUNCHER=1; shift ;;
    --yes|-y)    ASSUME_YES=1; shift ;;
    -h|--help)   awk 'NR>2 && /^# ═/{exit} NR>2 {sub(/^# ?/,""); print}' "$0"; exit 0 ;;
    *) printf '未知参数: %s\n' "$1" >&2; exit 1 ;;
  esac
done

say()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  ✅ %s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }
warn() { printf '  ⚠ %s\n' "$*"; }
die()  { printf '\n  ✖ %b\n' "$*" >&2; exit 1; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SRC/kernel/node_modules/@deepseek-ai/dsh/lib/bin.js" ] || die "包结构不完整：找不到 kernel/node_modules/@deepseek-ai/dsh/lib/bin.js"
[ -f "$SRC/runtime/bin/node" ] || die "包结构不完整：找不到 runtime/bin/node"
# 补执行位：tar 解压/跨机拷贝都可能丢 mode，装之前统一修一次
chmod 0755 "$SRC/runtime/bin/node" 2>/dev/null || true

say "安装 DeepSeek Harness（离线便携版）"
printf '  · 源  : %s\n  · 目标: %s\n' "$SRC" "$PREFIX"

df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {gb=$4/1048576; if (gb < 4) printf "  ⚠ 目标分区可用空间仅 %.1f GB，建议 ≥4GB\n", gb}'

say "① 部署应用文件"
mkdir -p "$PREFIX"
cp -a "$SRC/runtime" "$PREFIX/" || die "复制 runtime 失败"
cp -a "$SRC/kernel"  "$PREFIX/" || die "复制 kernel 失败"
chmod 0755 "$PREFIX/runtime/bin/node" 2>/dev/null || true   # 解压/拷贝可能丢执行位
cp -a "$SRC/home-template" "$PREFIX/" 2>/dev/null || true
cp -f "$SRC/install.sh" "$PREFIX/" 2>/dev/null || true
cp -f "$SRC/uninstall.sh" "$PREFIX/" 2>/dev/null || true
cp -f "$SRC/说明.md" "$PREFIX/" 2>/dev/null || true
cp -f "$SRC/README.md" "$PREFIX/" 2>/dev/null || true
ok "应用文件就位"

say "② 准备数据目录（DSH_HOME）"
DSH_HOME_DIR="${DSH_HOME:-$HOME/.dsh}"
mkdir -p "$DSH_HOME_DIR"
if [ -d "$PREFIX/home-template/profiles" ]; then
  # 只补缺失的插件树，不动用户已有的会话/凭据
  for p in "$PREFIX"/home-template/profiles/*; do
    [ -d "$p" ] || continue
    name="$(basename "$p")"
    if [ -d "$DSH_HOME_DIR/profiles/$name" ]; then
      info "profiles/$name 已存在，跳过（保留你现有的插件与配置）"
    else
      mkdir -p "$DSH_HOME_DIR/profiles"
      cp -a "$p" "$DSH_HOME_DIR/profiles/" && ok "profiles/$name 已部署"
    fi
  done
else
  info "本包未预装 profile 插件（--slim 构建），离线机启动时会自动跳过缺失的 bundle"
fi
ok "数据目录：$DSH_HOME_DIR"

say "③ 创建启动器"
if [ "$NO_LAUNCHER" = "1" ]; then
  info "已按 --no-launcher 跳过"
else
  BIN_DIR="$HOME/.local/bin"
  mkdir -p "$BIN_DIR"
  cat > "$BIN_DIR/dsh" <<LAUNCHER
#!/usr/bin/env bash
# DeepSeek Harness 启动器（自动生成，卸载时一起删除）
set -uo pipefail
PREFIX="$PREFIX"
export PATH="\$PREFIX/runtime/bin:\$PATH"
export DSH_HOME="\${DSH_HOME:-\$HOME/.dsh}"
exec "\$PREFIX/runtime/bin/node" "\$PREFIX/kernel/node_modules/@deepseek-ai/dsh/lib/bin.js" "\$@"
LAUNCHER
  chmod 0755 "$BIN_DIR/dsh"
  ok "启动器：$BIN_DIR/dsh"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR 不在 PATH 中。加入方法（bash）：
       echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc && source ~/.bashrc" ;;
  esac
fi

say "④ 冒烟自检"
V="$("$PREFIX/runtime/bin/node" --version 2>&1)"
DV="$(env PATH="$PREFIX/runtime/bin:$PATH" DSH_HOME="$DSH_HOME_DIR" \
      "$PREFIX/runtime/bin/node" "$PREFIX/kernel/node_modules/@deepseek-ai/dsh/lib/bin.js" --version 2>&1 | tail -1)"
ok "Node $V · dsh $DV"

cat <<TIP

════════════════════════════════════════════════════════════
 安装完成
════════════════════════════════════════════════════════════

 启动（Web UI，默认 127.0.0.1:3080）：
   dsh web                      本机浏览器会自动打开
   dsh web --no-open            只起服务，不自动开浏览器
   dsh web --no-open --port 8080

 想从别的机器访问（改成你机器的内网 IP）：
   dsh web --no-open --host 192.168.1.10 --trusted-host 192.168.1.10:3080

 首次使用需在页面里填 DeepSeek API Key（产品逻辑，需能访问 DeepSeek API）。

 安装目录：$PREFIX
 数据目录：$DSH_HOME_DIR
 卸载：bash $PREFIX/uninstall.sh
TIP
ok "完成"
EOF
chmod 0755 "$APP/install.sh"

cat > "$APP/uninstall.sh" <<'EOF'
#!/usr/bin/env bash
# DeepSeek Harness 离线包卸载（只删程序与启动器，默认保留你的会话数据）
set -uo pipefail

PREFIX="${DSH_PREFIX:-$HOME/.local/share/deepseek-harness}"
PURGE_DATA=0
ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --purge)  PURGE_DATA=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) awk 'NR>2 && /^# ═/{exit} NR>2 {sub(/^# ?/,""); print}' "$0"; exit 0 ;;
    *) printf '未知参数: %s\n' "$1" >&2; exit 1 ;;
  esac
done

say() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()  { printf '  ✅ %s\n' "$*"; }

say "卸载 DeepSeek Harness"
printf '  · 安装目录：%s\n' "$PREFIX"
if [ "$PURGE_DATA" = "1" ]; then
  printf '  · 数据目录：%s （--purge：一并删除）\n' "${DSH_HOME:-$HOME/.dsh}"
else
  printf '  · 数据目录：%s （保留；要连数据一起删加 --purge）\n' "${DSH_HOME:-$HOME/.dsh}"
fi
if [ "$ASSUME_YES" != "1" ]; then
  printf '\n确认删除？[y/N] '
  read -r ans
  case "$ans" in y|Y|yes|YES) ;; *) printf '已取消\n'; exit 0 ;; esac
fi

rm -rf "$PREFIX" && ok "已删除安装目录"
rm -f "$HOME/.local/bin/dsh" && ok "已删除启动器 ~/.local/bin/dsh"
if [ "$PURGE_DATA" = "1" ]; then
  rm -rf "${DSH_HOME:-$HOME/.dsh}" && ok "已删除数据目录"
fi
ok "卸载完成"
EOF
chmod 0755 "$APP/uninstall.sh"

cat > "$APP/说明.md" <<'EOF'
# DeepSeek Harness 离线便携包

免 root、免网络、免包管理器。解压后跑 `install.sh` 即可。

## 安装

```bash
bash install.sh                       # 装到 ~/.local/share/deepseek-harness
bash install.sh --prefix /data/dsh    # 装到别处（--prefix 可换任意可写目录）
bash install.sh --no-launcher         # 不建 ~/.local/bin/dsh
```

## 启动

```bash
dsh web                    # 起 Web UI，默认 http://127.0.0.1:3080（本机自动开浏览器）
dsh web --no-open          # 只起服务
dsh web --no-open --port 8080
dsh web --no-open --host 192.168.1.10 --trusted-host 192.168.1.10:3080   # 允许内网其它机器访问
```

- `~/.local/bin` 不在 PATH 时：
  `echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc`
- 没有图形界面/不想装：用包内直启 `./dsh web --no-open`（数据落在包内 `./home`）。

## 目录

| 路径 | 作用 |
|---|---|
| `<prefix>/runtime` | 内置 Node 运行时（不碰系统 Node） |
| `<prefix>/kernel` | dsh 及全部依赖 |
| `<prefix>/home-template` | 预装的 profile 插件树（安装时并入 `~/.dsh`） |
| `~/.dsh` | 会话、凭据、插件（升级/重装不丢） |

## 卸载

```bash
bash uninstall.sh            # 保留会话数据
bash uninstall.sh --purge    # 连 ~/.dsh 一起删
```

## 注意

- 首次使用要在页面里配置 **DeepSeek API Key**；调用模型本身需要能访问 DeepSeek API。
- 银河麒麟：若报 `KYSEC: 权限不够`，先 `sudo setstatus softmode`，
  或在「安全管理中心」把安装目录与 `~/.dsh` 加入信任白名单。
- 部分实验性 bundle（如 dsh-im）与当前 dsh 运行时版本不兼容，启动时会打印
  `skipping profile bundle` 并跳过——这是上游现状，Web UI 主体不受影响。
EOF

cat > "$APP/README.md" <<'EOF'
# DeepSeek Harness — offline portable bundle

Root-free, network-free, package-manager-free.

```bash
bash install.sh                 # installs to ~/.local/share/deepseek-harness
dsh web                         # Web UI on http://127.0.0.1:3080
dsh web --no-open --host <ip> --trusted-host <ip>:3080   # LAN access
bash uninstall.sh               # remove (keeps ~/.dsh data)
```

See 说明.md (Chinese) for details.
EOF
ok "启动器 / install.sh / uninstall.sh / 说明.md 已生成"

# ── ⑥ 打包 ────────────────────────────────────────────────────────────────
say "⑥ 打包"
# 打包前统一修一次权限，避免解压端（尤其跨机器拷贝后）拿到没有执行位的文件
chmod 0755 "$APP/dsh" "$APP/install.sh" "$APP/uninstall.sh" 2>/dev/null || true
chmod 0755 "$APP"/runtime/bin/node "$APP"/runtime/bin/npm "$APP"/runtime/bin/npx 2>/dev/null || true
STAGE_NAME="deepseek-harness-$DSH_VERSION-offline-$ARCH"
mv "$APP" "$STAGE/$STAGE_NAME" || die "整理目录失败"
TARBALL_OUT="$OUT/$STAGE_NAME.tar.gz"
tar -czf "$TARBALL_OUT" -C "$STAGE" "$STAGE_NAME" || die "打包失败"
SHA="$(sha256sum "$TARBALL_OUT" | awk '{print $1}')"
SIZE="$(du -h "$TARBALL_OUT" | cut -f1)"
printf '%s  %s\n' "$SHA" "$(basename "$TARBALL_OUT")" > "$OUT/$STAGE_NAME.sha256"
printf 'version   : %s\narch      : %s\nnode      : %s\nfile      : %s\nsize      : %s\nsha256    : %s\nplugins   : %s\n' \
  "$DSH_VERSION" "$ARCH" "$NODE_RUNTIME_VER" "$(basename "$TARBALL_OUT")" "$SIZE" "$SHA" \
  "$([ "$SLIM" = "1" ] && echo 'not bundled (--slim)' || echo 'bundled')" > "$OUT/$STAGE_NAME.MANIFEST.txt"

say "构建完成"
ok "产物：$TARBALL_OUT"
ok "体积：$SIZE  sha256：$SHA"
cat <<TIP

离线机上安装：
  tar -xzf $(basename "$TARBALL_OUT")
  cd $STAGE_NAME
  bash install.sh
  dsh web --no-open            # 然后浏览器访问 http://127.0.0.1:3080
TIP
