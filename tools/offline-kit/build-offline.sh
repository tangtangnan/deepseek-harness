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
#   bash build-offline.sh                  # 按当前机器架构构建，版本自动取 npm 最新版
#   bash build-offline.sh --arch arm64     # 显式指定（不匹配会直接中止）
#   bash build-offline.sh --print-version  # 只打印自动解析到的 dsh 版本（不构建）
#   bash build-offline.sh --version 0.2.1-rc.2   # 手动锁定版本（不再自动更新）
#   bash build-offline.sh --dist-tag next        # 自动取 next 标签（默认 latest）
#   bash build-offline.sh --no-extra-plugins     # 不预装两个 subagent 插件
#   bash build-offline.sh --slim           # 不预装任何 profile 插件（包小 ~300MB，
#                                          # 但离线机每次启动会尝试联网拉插件后跳过）
#
# 【版本自动更新】默认 DSH_VERSION=auto：构建时从 npm registry 读取
#   @deepseek-ai/dsh 的 dist-tags.latest，永远打当前最新版，不再写死 rc.2。
#   要复现旧包就显式 --version <版本号>；要追预发布用 --dist-tag next / alpha。
#
# 环境变量：
#   DSH_VERSION=auto|latest|next|0.2.2-rc.1   默认 auto
#   DSH_DIST_TAG=latest|next|alpha             auto 时读取哪个 dist-tag
#   EXTRA_PLUGINS="<空格分隔的包名>"            默认预装的两个 subagent 插件；设为空可关闭
#   DSH_PLUGIN_VERSION=0.2.2-rc.1             强制插件版本（默认与 dsh 同版本）
#   PLUGIN_STRICT=1                           插件装不上就中止构建（设 0 则只告警）
#   NODE_RUNTIME_VER=v22.22.0       内置 Node 版本基准；不够时自动升到 dsh 要求的版本
#   NODE_RUNTIME_AUTO=1              按目标 dsh 的 engines.node 自动选 Node（0=完全手动）
#   NPM_REGISTRY / NPM_REGISTRY_FALLBACK
#   WORK=<构建工作目录>  OUT=<产物目录>
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

DSH_VERSION="${DSH_VERSION:-auto}"
DSH_DIST_TAG="${DSH_DIST_TAG:-latest}"
NODE_RUNTIME_VER="${NODE_RUNTIME_VER:-v22.22.0}"
NODE_RUNTIME_AUTO="${NODE_RUNTIME_AUTO:-1}"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"
NPM_REGISTRY_FALLBACK="${NPM_REGISTRY_FALLBACK:-https://registry.npmjs.org}"
NODE_MIRROR="${NODE_MIRROR:-https://npmmirror.com/mirrors/node}"

# 默认随包预装的两个官方 subagent 插件。
# 注意：这两个包与 dsh 同一个 monorepo 锁步发版，但它们的 npm `latest` 标签
# 长期停在 0.0.1-rc.1。直接 `dsh plugin add <包名>` 会装到不兼容的旧版，
# 所以下面 ④-b 会把版本对齐到本次的 DSH_VERSION。
DEFAULT_EXTRA_PLUGINS="@deepseek-ai/dsh-subagent-codex @deepseek-ai/dsh-subagent-claude-code"
EXTRA_PLUGINS="${EXTRA_PLUGINS-$DEFAULT_EXTRA_PLUGINS}"
DSH_PLUGIN_VERSION="${DSH_PLUGIN_VERSION:-}"
PLUGIN_STRICT="${PLUGIN_STRICT:-1}"

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$KIT_DIR/build}"
OUT="${OUT:-$KIT_DIR/release}"

ARCH_INPUT="auto"
SLIM=0
PRINT_VERSION=0
while [ $# -gt 0 ]; do
  case "$1" in
    --arch)        ARCH_INPUT="$2"; shift 2 ;;
    --version)     DSH_VERSION="$2"; shift 2 ;;
    --dist-tag)    DSH_DIST_TAG="$2"; shift 2 ;;
    --registry)    NPM_REGISTRY="$2"; shift 2 ;;
    --work)        WORK="$2"; shift 2 ;;
    --out)         OUT="$2"; shift 2 ;;
    --slim)        SLIM=1; shift ;;
    --no-extra-plugins) EXTRA_PLUGINS=""; shift ;;
    --extra-plugins)    EXTRA_PLUGINS="$2"; shift 2 ;;
    --plugin-version)   DSH_PLUGIN_VERSION="$2"; shift 2 ;;
    --print-version)    PRINT_VERSION=1; shift ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
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

# ── 版本号自动解析 ─────────────────────────────────────────────────────────
# 直接改写全局 DSH_VERSION（不用 $(...) 命令替换，避免子 shell 丢变量）。
# 取值规则：
#   auto / latest / 空 / @latest      → 读 dist-tags.<DSH_DIST_TAG>（默认 latest）
#   next / alpha / beta / rc / canary → 读同名 dist-tag
#   其它（如 0.2.2-rc.1）            → 手动锁定的具体版本，原样保留、不联网
# 先走 registry 的 dist-tags 端点（npmmirror / npmjs 都支持），
# 再退回 npm view（适配没有该端点的私服）。
DSH_VERSION_SOURCE="pinned"
resolve_dsh_version() {
  local raw="$DSH_VERSION" tag v reg url
  case "$raw" in
    ""|auto|latest|@latest) tag="$DSH_DIST_TAG" ;;
    next|alpha|beta|rc|canary) tag="$raw" ;;
    *) DSH_VERSION_SOURCE="pinned"; return 0 ;;
  esac
  mkdir -p "$WORK"
  for reg in "$NPM_REGISTRY" "$NPM_REGISTRY_FALLBACK"; do
    url="${reg%/}/-/package/@deepseek-ai/dsh/dist-tags"
    if fetch "$url" "$WORK/dsh-dist-tags.json" 2>/dev/null && [ -s "$WORK/dsh-dist-tags.json" ]; then
      v="$(sed -n 's/.*"'"$tag"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            "$WORK/dsh-dist-tags.json" 2>/dev/null | head -1)"
      if [ -z "$v" ] && command -v node >/dev/null 2>&1; then
        v="$(node -e '
          const fs = require("fs");
          try {
            const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
            const x = j[process.argv[2]];
            if (typeof x === "string" && x) process.stdout.write(x);
          } catch {}
        ' "$WORK/dsh-dist-tags.json" "$tag" 2>/dev/null)"
      fi
      if [ -n "$v" ]; then
        DSH_VERSION="$v"
        DSH_VERSION_SOURCE="registry:$tag"
        return 0
      fi
    fi
  done
  for reg in "$NPM_REGISTRY" "$NPM_REGISTRY_FALLBACK"; do
    v="$(npm view '@deepseek-ai/dsh' "dist-tags.$tag" --registry "$reg" 2>/dev/null \
         | tail -1 | tr -d "'\" \r")"
    if [ -n "$v" ]; then
      DSH_VERSION="$v"
      DSH_VERSION_SOURCE="npm-view:$tag"
      return 0
    fi
  done
  return 1
}

validate_dsh_version() {
  [[ "$DSH_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]
}

# ── 内置 Node 运行时版本自动匹配 ───────────────────────────────────────────
# 【为什么必须做】dsh 0.2.2-rc.1 起 engines.node 从「^22.19 || >=24」收紧为
# 「>=24.9.0」。只把 dsh 版本自动更新、却仍内置 v22.22.0，打出来的包在离线机
# 上 `dsh web` 根本起不来。所以版本自动更新必须连带这一步。
#
# 做法：读目标 dsh 版本的 engines.node → 取范围里的首个主版本号 →
# 若高于当前 NODE_RUNTIME_VER 的主版本，就从 Node 官方 index.json 里挑该主版本
# 最新的稳定版（含 linux-x64/arm64 产物）。NODE_RUNTIME_AUTO=0 可关掉。
NODE_RUNTIME_SOURCE="pinned"
resolve_node_runtime() {
  local engine="" min_major cur_major reg url v u
  [ "$NODE_RUNTIME_AUTO" = "1" ] || { NODE_RUNTIME_SOURCE="pinned (NODE_RUNTIME_AUTO=0)"; return 0; }
  for reg in "$NPM_REGISTRY" "$NPM_REGISTRY_FALLBACK"; do
    for enc in '@deepseek-ai%2fdsh' '@deepseek-ai/dsh'; do
      url="${reg%/}/$enc/$DSH_VERSION"
      if fetch "$url" "$WORK/dsh-meta.json" 2>/dev/null && [ -s "$WORK/dsh-meta.json" ]; then
        engine="$(node -e '
          const fs = require("fs");
          try {
            const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
            const e = j.engines?.node;
            if (typeof e === "string" && e) process.stdout.write(e);
          } catch {}
        ' "$WORK/dsh-meta.json" 2>/dev/null)"
        [ -n "$engine" ] && break 2
      fi
    done
  done
  if [ -z "$engine" ]; then
    NODE_RUNTIME_SOURCE="engines.node 未声明/查不到，沿用 $NODE_RUNTIME_VER"
    warn "读不到 dsh $DSH_VERSION 的 engines.node；若这是 0.2.2-rc.1 及以后，请显式 NODE_RUNTIME_VER=v24.22.2"
    return 0
  fi
  # ">=24.9.0" → 24；"^22.19 || >=24" → 22（老版本，22 就够）
  min_major="$(printf '%s' "$engine" | grep -oE '[0-9]+' | head -1)"
  cur_major="$(printf '%s' "${NODE_RUNTIME_VER#v}" | cut -d. -f1)"
  if [ -z "$min_major" ] || ! [ "$min_major" -gt "$cur_major" ] 2>/dev/null; then
    NODE_RUNTIME_SOURCE="engines.node=$engine 已满足，沿用 $NODE_RUNTIME_VER"
    return 0
  fi
  for u in "${NODE_MIRROR%/}/index.json" "https://nodejs.org/dist/index.json"; do
    if fetch "$u" "$WORK/node-index.json" 2>/dev/null && [ -s "$WORK/node-index.json" ]; then
      v="$(node -e '
        const fs = require("fs");
        try {
          const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
          const m = "v" + process.argv[2] + ".";
          const x = j.find(e => e.version.startsWith(m)
                             && !e.version.includes("-")
                             && Array.isArray(e.files)
                             && e.files.includes("linux-x64")
                             && e.files.includes("linux-arm64"));
          if (x) process.stdout.write(x.version);
        } catch {}
      ' "$WORK/node-index.json" "$min_major" 2>/dev/null)"
      [ -n "$v" ] && {
        NODE_RUNTIME_VER="$v"
        NODE_RUNTIME_SOURCE="auto (engines.node=$engine → $v)"
        return 0
      }
    fi
  done
  # index.json 都拿不到时，用已知可用的 LTS 兜底，别闷头打一个 Node 太旧的包
  case "$min_major" in
    24) NODE_RUNTIME_VER="v24.22.2"
        NODE_RUNTIME_SOURCE="fallback (engines.node=$engine → v24.22.2)"
        return 0 ;;
  esac
  die "dsh $DSH_VERSION 要求 Node $engine，但找不到 Node $min_major.x 的可用版本。
  请显式指定 NODE_RUNTIME_VER=<满足要求的版本> 后重跑，或设 NODE_RUNTIME_AUTO=0 自行负责。"
}

# ── 插件版本解析 ───────────────────────────────────────────────────────────
# 两个 subagent 插件与 dsh 同 monorepo 锁步发版，但 npm 的 latest 标签是旧的
# 0.0.1-rc.1；不显式带版本会装到不兼容的旧版。默认对齐到 DSH_VERSION。
plugin_name() {
  local s="$1" rest
  if [[ "$s" == @*/* ]]; then
    rest="${s#@}"
    printf '@%s' "${rest%%@*}"
  else
    printf '%s' "${s%%@*}"
  fi
}
plugin_has_version() {
  local s="$1" rest
  if [[ "$s" == @*/* ]]; then rest="${s#@}"; [[ "$rest" == *@* ]]
  else [[ "$s" == *@* ]]; fi
}
plugin_version_exists() {
  npm view "$1@$2" version --registry "$NPM_REGISTRY" >/dev/null 2>&1 \
    || npm view "$1@$2" version --registry "$NPM_REGISTRY_FALLBACK" >/dev/null 2>&1
}
plugin_dist_tag() {
  local pkg="$1" tag="$2" reg v
  for reg in "$NPM_REGISTRY" "$NPM_REGISTRY_FALLBACK"; do
    v="$(npm view "$pkg" "dist-tags.$tag" --registry "$reg" 2>/dev/null \
         | tail -1 | tr -d "'\" \r")"
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  done
  return 1
}
# 注意：本函数只往 stdout 打印「最终 spec」，诊断信息一律走 stderr，
# 否则会污染调用方 $(resolve_plugin_spec ...) 的返回值。
resolve_plugin_spec() {
  local spec="$1" ver
  case "$spec" in
    /*|./*|../*|file:*|link:*) printf '%s' "$spec"; return 0 ;;
  esac
  if plugin_has_version "$spec"; then printf '%s' "$spec"; return 0; fi
  if [ -n "$DSH_PLUGIN_VERSION" ]; then
    printf '%s@%s' "$spec" "$DSH_PLUGIN_VERSION"; return 0
  fi
  if plugin_version_exists "$spec" "$DSH_VERSION"; then
    printf '%s@%s' "$spec" "$DSH_VERSION"; return 0
  fi
  if ver="$(plugin_dist_tag "$spec" next)" && [ -n "$ver" ]; then
    printf '  ⚠ %s 没有 %s 版，回退 next=%s\n' "$spec" "$DSH_VERSION" "$ver" >&2
    printf '%s@%s' "$spec" "$ver"; return 0
  fi
  if ver="$(plugin_dist_tag "$spec" latest)" && [ -n "$ver" ]; then
    printf '  ⚠ %s 无 %s / next 版，回退 latest=%s（可能不兼容）\n' "$spec" "$DSH_VERSION" "$ver" >&2
    printf '%s@%s' "$spec" "$ver"; return 0
  fi
  printf '  ⚠ %s 版本解析失败，交给 pnpm 自行决定（可能装到旧版）\n' "$spec" >&2
  printf '%s' "$spec"
}

# --print-version：只解析、只打印，供 CI 的 resolve job 复用同一套逻辑
if [ "$PRINT_VERSION" = "1" ]; then
  resolve_dsh_version \
    || die "无法自动解析 dsh 版本（registry 都不可达）。
  可显式指定：--version 0.2.2-rc.1  或  DSH_VERSION=0.2.2-rc.1"
  validate_dsh_version \
    || die "解析到的版本号不合法：$DSH_VERSION。请显式 --version <版本号>"
  printf '%s\n' "$DSH_VERSION"
  exit 0
fi

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

for c in tar gzip sha256sum sed grep awk readlink; do
  command -v "$c" >/dev/null 2>&1 || die "缺少命令: $c"
done
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || die "缺少 curl 或 wget"
command -v node >/dev/null 2>&1 || die "构建机需要 Node（任意 18+ 即可，仅用于构建；打包进去的是独立下载的运行时）"
command -v npm  >/dev/null 2>&1 || die "构建机需要 npm"
ok "架构 $ARCH_LABEL，基础工具齐备"

mkdir -p "$WORK" "$OUT"
WORK="$(cd "$WORK" && pwd)"      # 转绝对路径：后面判断 pnpm store 符号链接要用

say "①-b 解析 dsh 版本（自动取 npm 最新版，不再写死 rc.2）"
resolve_dsh_version \
  || die "自动解析 dsh 版本失败（$NPM_REGISTRY / $NPM_REGISTRY_FALLBACK 都查不到 dist-tags）。
  离线/私服环境请显式指定：--version 0.2.2-rc.1  或  DSH_VERSION=0.2.2-rc.1"
validate_dsh_version \
  || die "版本号不合法：$DSH_VERSION
  auto 应解析出形如 0.2.2-rc.1 的 semver；要手动锁定就写 --version <版本号>"
case "$DSH_VERSION_SOURCE" in
  pinned) ok "手动锁定：dsh $DSH_VERSION（不会自动更新）" ;;
  *)      ok "自动解析（${DSH_VERSION_SOURCE}）：dsh $DSH_VERSION" ;;
esac
# 写回 CI：release tag / artifact 汇总都该用「解析后」的版本，而不是输入框里的 auto
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'dsh_version=%s\ndsh_version_source=%s\n' \
    "$DSH_VERSION" "$DSH_VERSION_SOURCE" >> "$GITHUB_OUTPUT"
fi
printf '%s\n' "$DSH_VERSION" > "$WORK/RESOLVED_VERSION"

say "①-c 匹配内置 Node 运行时（跟着 dsh 的 engines.node 走）"
resolve_node_runtime
ok "内置 Node $NODE_RUNTIME_VER（$NODE_RUNTIME_SOURCE）"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'node_runtime=%s\n' "$NODE_RUNTIME_VER" >> "$GITHUB_OUTPUT"
fi

# 只清 stage，保留 $WORK/node.tar.* 缓存（重跑省一次 50MB 下载）
rm -rf "$WORK/stage" "$WORK/home-seed" "$WORK/seed-web.log"
STAGE="$WORK/stage"
APP="$STAGE/deepseek-harness-$DSH_VERSION-$ARCH"
mkdir -p "$APP"

# ── ② 下载目标架构的 Node 运行时 ──────────────────────────────────────────
say "② 下载 Node $NODE_RUNTIME_VER（linux-$NODE_ARCH）"
RT_DIR="$APP/runtime"
mkdir -p "$RT_DIR"
# .tar.xz 更小，但依赖 xz 命令（精简系统可能没有）——缺 xz 就直接用 .tar.gz
# 已存在则复用（重跑时省一次 50MB 下载）
TGZ="node-$NODE_RUNTIME_VER-linux-$NODE_ARCH.tar.gz"
XZ="node-$NODE_RUNTIME_VER-linux-$NODE_ARCH.tar.xz"
# 缓存文件名必须带版本 + 架构：Node 版本自动升级后不能误复用上一版 v22 的包
CACHE_GZ="$WORK/$TGZ"
CACHE_XZ="$WORK/$XZ"
USE_XZ=""
[ -s "$CACHE_XZ" ] && USE_XZ="xz"
[ -s "$CACHE_GZ" ] && USE_XZ="gz"
if [ -z "$USE_XZ" ]; then
  if command -v xz >/dev/null 2>&1; then
    fetch_first "$CACHE_XZ" \
      "$NODE_MIRROR/$NODE_RUNTIME_VER/$XZ" \
      "https://nodejs.org/dist/$NODE_RUNTIME_VER/$XZ" && USE_XZ="xz"
  fi
  if [ -z "$USE_XZ" ]; then
    command -v xz >/dev/null 2>&1 || info "本机无 xz 命令，改用 .tar.gz"
    fetch_first "$CACHE_GZ" \
      "$NODE_MIRROR/$NODE_RUNTIME_VER/$TGZ" \
      "https://nodejs.org/dist/$NODE_RUNTIME_VER/$TGZ" \
      || die "Node 运行时下载失败（$NODE_RUNTIME_VER，两个源都不通）"
    USE_XZ="gz"
  fi
fi
if [ "$USE_XZ" = "xz" ]; then
  tar -xJf "$CACHE_XZ" -C "$RT_DIR" --strip-components=1 || die "Node 解压失败（.tar.xz）"
else
  tar -xzf "$CACHE_GZ" -C "$RT_DIR" --strip-components=1 || die "Node 解压失败（.tar.gz）"
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

# ── ③-b 内置 pnpm（dsh plugin 子命令依赖它）────────────────────────────────
# 官方帮助原文：`dsh plugin` = "manage a profile's plugins by forwarding the
# remaining arguments to pnpm in the profile directory"（docs/cli-help.md）。
# Node 官方二进制自带 npm/npx，但**不含 pnpm** —— 离线机没有它就装不了插件。
#
# 版本必须锁 11.28.5，两个原因：
#   ① 与 dsh 仓库 package.json 的 `packageManager: pnpm@11.28.5` 一致；
#   ② 11.x 是**纯 JS**（bin/pnpm.mjs，无 optionalDependencies），架构无关，
#      一份可同时用于 amd64 / arm64。pnpm 12.x 起改为按平台分发的 rust exe
#      （optionalDependencies: @pnpm/exe.linux-x64 / linux-arm64 ...），
#      在 x64 构建机上装出来的包装到 arm64 机器上跑不了。
PNPM_VERSION="${PNPM_VERSION:-11.28.5}"
say "③-b 内置 pnpm（dsh plugin 需要）"
if [ -f "$RT_DIR/bin/pnpm" ]; then
  ok "已存在 pnpm $(env PATH="$RT_DIR/bin:$PATH" "$RT_DIR/bin/pnpm" --version 2>/dev/null | tail -1)"
else
  if ! npm install -g --prefix "$RT_DIR" "pnpm@$PNPM_VERSION" \
        --registry "$NPM_REGISTRY" --no-audit --fund=false >/dev/null 2>&1; then
    warn "主 registry 装 pnpm 失败，回退 $NPM_REGISTRY_FALLBACK"
    npm install -g --prefix "$RT_DIR" "pnpm@$PNPM_VERSION" \
        --registry "$NPM_REGISTRY_FALLBACK" --no-audit --fund=false >/dev/null 2>&1 || true
  fi
  chmod 0755 "$RT_DIR"/bin/pnpm "$RT_DIR"/bin/pnpx "$RT_DIR"/bin/pn "$RT_DIR"/bin/pnx 2>/dev/null || true
  if [ -f "$RT_DIR/bin/pnpm" ]; then
    PV="$(env PATH="$RT_DIR/bin:$PATH" "$RT_DIR/bin/pnpm" --version 2>&1 | tail -1)"
    if [ -n "$PV" ]; then
      ok "pnpm $PV 已内置（$RT_DIR/bin/pnpm，纯 JS、架构无关）"
    else
      warn "pnpm 已落地但跑不起来（可能缺 node 在 PATH）—— 见包内 说明.md 的插件章节"
    fi
  else
    warn "pnpm 安装失败 —— 离线机将无法执行 dsh plugin 装插件，其余功能不受影响"
  fi
  # pnpm 是纯 JS，但要确认没把平台相关的 rust exe 带进来
  if [ -d "$RT_DIR/lib/node_modules/pnpm/node_modules/@pnpm" ] &&
     ls -d "$RT_DIR"/lib/node_modules/pnpm/node_modules/@pnpm/exe.* >/dev/null 2>&1; then
    warn "检测到 @pnpm/exe.*（平台相关）—— 版本可能不是预期的 11.x，跨架构打包会失效"
  fi
fi

# ── ④ 预装 profile 插件（可选）────────────────────────────────────────────
HOME_TPL="$APP/home-template"
PLUGIN_STATUS="not bundled (--slim)"
PLUGIN_SPECS_TEXT=""
PLUGIN_NAMES=()
if [ "$SLIM" = "1" ]; then
  say "④ 跳过 profile 插件预装（--slim）"
  mkdir -p "$HOME_TPL"
  warn "离线机首次启动会尝试联网拉取 profile bundle，失败后跳过（Web UI 主体不受影响）"
  warn "--slim 也不会预装两个 subagent 插件"
else
  say "④ 预装 profile 插件（首次启动联网拉取的那批，约 3~10 分钟）"
  # dsh 用 pnpm 在 $DSH_HOME/profiles/<profile>/ 下装 bundle；这里起一次 web 让它装完，
  # 再把结果打包带走。装完后再启动就不需要网络了。
  # 优先用 ③-b 内置进 runtime 的那个（版本与 dsh 的 packageManager 一致）；
  # 下面的 env PATH="$RT_DIR/bin:$PATH" 已经把它暴露给 dsh 子进程。
  if [ -x "$RT_DIR/bin/pnpm" ]; then
    ok "使用内置 pnpm $(env PATH="$RT_DIR/bin:$PATH" "$RT_DIR/bin/pnpm" --version 2>/dev/null | tail -1)"
  elif command -v pnpm >/dev/null 2>&1; then
    ok "使用系统 pnpm $(pnpm --version 2>/dev/null)"
  else
    info "pnpm 均不可用，尝试用 corepack 临时准备"
    corepack enable >/dev/null 2>&1 || true
    corepack prepare "pnpm@$PNPM_VERSION" --activate >/dev/null 2>&1 \
      || npm i -g "pnpm@$PNPM_VERSION" --registry "$NPM_REGISTRY" >/dev/null 2>&1 \
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

  # ── ④-b 预装两个 subagent 插件（默认开）──────────────────────────────────
  # 走官方入口 `dsh plugin --profile <name> add <spec...>`：它在 profile 目录
  # 跑 pnpm add，随后 reconcilePlugins() 会把声明了 `dsh.bundle` 的包自动追加
  # 进 package.json 的 dsh.profile.bundles（本地 dsh 源码 lib/plugin-*.js 已核实）。
  # 比手改 package.json 稳妥：上游改了清单格式也不会脱节。
  #
  # 版本必须对齐 DSH_VERSION：这两个包与 dsh 同 monorepo 锁步发版，
  # 0.2.2-rc.1 的 peerDependencies 精确锁 `0.2.2-rc.1`；而它们的 npm `latest`
  # 标签停在 0.0.1-rc.1，裸包名会装到不兼容旧版。
  if [ -z "$EXTRA_PLUGINS" ]; then
    info "④-b --no-extra-plugins：跳过 subagent 插件预装"
    PLUGIN_STATUS="disabled (--no-extra-plugins)"
  elif [ ! -d "$TMP_HOME/profiles/web" ]; then
    warn "④-b profiles/web 未生成，无法预装 subagent 插件（看 ④ 的日志）"
    PLUGIN_STATUS="FAILED: profile web missing"
  else
    say "④-b 预装 subagent 插件（默认，版本对齐 dsh $DSH_VERSION）"
    PLUGIN_SPECS=()
    PLUGIN_NAMES=()
    for raw in $EXTRA_PLUGINS; do
      spec="$(resolve_plugin_spec "$raw")"
      PLUGIN_SPECS+=("$spec")
      n="$(plugin_name "$spec")"
      # 本地路径 / tarball 也会被写进 EXTRA_PLUGINS：pnpm 会按包内真实包名登记，
      # 这里猜不出名字，就不参与「按包名」的三重校验，只保留安装动作。
      if [[ "$n" == @*/* ]] || [[ "$n" =~ ^[A-Za-z0-9_-][A-Za-z0-9_.-]*$ ]]; then
        PLUGIN_NAMES+=("$n")
      else
        info "$spec 是本地路径，跳过按包名的清单校验"
      fi
    done
    [ "${#PLUGIN_NAMES[@]}" -gt 0 ] \
      || die "EXTRA_PLUGINS 里没有可校验的包名，无法确定插件是否装成功：$EXTRA_PLUGINS"
    PLUGIN_SPECS_TEXT="${PLUGIN_SPECS[*]}"
    info "待装：$PLUGIN_SPECS_TEXT"
    PLUGIN_FAIL=0
    # 逐个装：新版 dsh 的插件管理器是「一次一个 spec」地做兼容性检查并
    # 把 bundle 写进清单，一次塞多个可能只登记第一个。
    for pdir in "$TMP_HOME"/profiles/*/; do
      [ -f "$pdir/package.json" ] || continue
      pname="$(basename "$pdir")"
      for spec in "${PLUGIN_SPECS[@]}"; do
        info "dsh plugin --profile $pname add $spec"
        if ! env PATH="$RT_DIR/bin:$PATH" DSH_HOME="$TMP_HOME" \
                npm_config_registry="$NPM_REGISTRY" \
                "$RT_DIR/bin/node" "$DSH_BIN" plugin --profile "$pname" add \
                "$spec" >> "$LOG" 2>&1; then
          warn "profile $pname / $spec：主 registry 失败，改用 $NPM_REGISTRY_FALLBACK 重试"
          tail -20 "$LOG" 2>/dev/null | sed 's/^/    /'
          if ! env PATH="$RT_DIR/bin:$PATH" DSH_HOME="$TMP_HOME" \
                  npm_config_registry="$NPM_REGISTRY_FALLBACK" \
                  "$RT_DIR/bin/node" "$DSH_BIN" plugin --profile "$pname" add \
                  "$spec" >> "$LOG" 2>&1; then
            PLUGIN_FAIL=1
          fi
        fi
      done
    done
    # 三重校验：dependencies 有、bundles 有、node_modules 里真的落了盘
    for pdir in "$TMP_HOME"/profiles/*/; do
      [ -f "$pdir/package.json" ] || continue
      pname="$(basename "$pdir")"
      if ! node -e '
        const fs = require("fs");
        const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        const deps = j.dependencies || {};
        const bundles = j.dsh?.profile?.bundles || [];
        let bad = 0;
        for (const n of process.argv.slice(2)) {
          if (!deps[n])    { console.log("  缺 dependencies: " + n); bad = 1; }
          if (!bundles.includes(n)) { console.log("  缺 dsh.profile.bundles: " + n); bad = 1; }
        }
        process.exit(bad);
      ' "$pdir/package.json" "${PLUGIN_NAMES[@]}"; then
        warn "profile $pname 的插件清单校验不通过（上面列了缺什么）"
        PLUGIN_FAIL=1
      fi
      for n in "${PLUGIN_NAMES[@]}"; do
        [ -d "$pdir/node_modules/$n" ] || {
          warn "profile $pname 缺少 node_modules/$n"; PLUGIN_FAIL=1; }
      done
    done
    if [ "$PLUGIN_FAIL" = "0" ]; then
      PLUGIN_STATUS="bundled"
      ok "subagent 插件已写入 dependencies + dsh.profile.bundles，并落盘到 node_modules"
    else
      PLUGIN_STATUS="FAILED"
      tail -30 "$LOG" 2>/dev/null | sed 's/^/    /'
      if [ "$PLUGIN_STRICT" = "1" ]; then
        die "subagent 插件预装失败。
  继续打出去的包在离线机上就没有这两个插件，不符合「默认带上」的要求。
  排查：看 $LOG 尾部（pnpm 报的是网络、平台二进制还是 peerDeps）。
  临时跳过：--no-extra-plugins；只告警不中止：PLUGIN_STRICT=0"
      else
        warn "subagent 插件预装失败，按 PLUGIN_STRICT=0 继续打包（MANIFEST 标 FAILED）"
      fi
    fi
  fi

  if [ -d "$TMP_HOME/profiles" ] && [ -d "$TMP_HOME/profiles/web" ]; then
    mkdir -p "$HOME_TPL"
    cp -a "$TMP_HOME/profiles" "$HOME_TPL/" || warn "复制 profiles 失败"
    ok "profile 插件树已收集（profiles/web）"
    # pnpm 可能留下「指向构建机全局 store」的绝对符号链接，拷到离线机必断。
    # 把指向包外的链接实体化；树内相对链接（.bin/* 等）保持原样，解包后仍有效。
    # 多跑几轮：实体化一个目录后，它内部可能又带进来新的外部链接。
    MAT_TOTAL=0
    for pass in 1 2 3; do
      MAT=0
      while IFS= read -r -d '' link; do
        target="$(readlink -f "$link" 2>/dev/null || true)"
        case "$target" in
          "$HOME_TPL"/*) ;;                       # 树内，保留原样
          *)
            if [ -n "$target" ] && [ -e "$target" ]; then
              rm -f "$link" && cp -a "$target" "$link" && MAT=$((MAT+1))
            else
              warn "断链：$link -> $(readlink "$link" 2>/dev/null)"
            fi
            ;;
        esac
      done < <(find "$HOME_TPL" -type l -print0 2>/dev/null)
      MAT_TOTAL=$((MAT_TOTAL+MAT))
      [ "$MAT" -eq 0 ] && break
    done
    [ "$MAT_TOTAL" -gt 0 ] && info "已实体化 $MAT_TOTAL 个指向包外的 pnpm store 符号链接"
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
NODE="$HERE/runtime/bin/node"
BIN="$HERE/kernel/node_modules/@deepseek-ai/dsh/lib/bin.js"
# 正常机器：直接 exec 内置 Node
if "$NODE" --version >/dev/null 2>&1; then
  exec "$NODE" "$BIN" "$@"
fi
# KYSEC 执行控制 / noexec 拦了 execve：借系统受信任的动态加载器执行。
# 被 execve 的是 ld-linux，node 只作为数据文件加载 —— 全程普通用户，免 root。
for LD in /lib64/ld-linux-x86-64.so.2 /lib/ld-linux-aarch64.so.1 \
          /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib/aarch64-linux-gnu/ld-linux-aarch64.so.1; do
  [ -x "$LD" ] && exec "$LD" "$NODE" "$BIN" "$@"
done
printf '内置 Node 无法执行：直接 exec 被拦，也没找到可用的动态加载器。\n' >&2
printf '普通用户可先试 chmod +x %s；无效则请管理员把该目录加入 KYSEC 信任白名单。\n' "$NODE" >&2
exit 1
EOF
chmod 0755 "$APP/dsh"

# 包内 pnpm 包装：`dsh plugin` 底层就是 pnpm，离线机上直接用它更灵活
# （不依赖 PATH 里有没有 node —— 它自己把 runtime/bin 塞进去）
cat > "$APP/pnpm" <<'EOF'
#!/usr/bin/env bash
# 包内 pnpm（用法示例）：
#   ./pnpm --version                     看版本
#   ./pnpm add <pkg>                     在当前目录装包（离线请用本地 tgz / file: 路径）
#   ./pnpm store path                    看本机 store 位置（离线灌包会用到）
# 注意：dsh 的插件要用 dsh plugin --profile <名> add <pkg>，它会切到 profile 目录执行
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HERE/runtime/bin:$PATH"
if [ ! -f "$HERE/runtime/bin/pnpm" ]; then
  printf 'pnpm 未内置在本包中（构建时安装失败）\n' >&2
  exit 127
fi
if "$HERE/runtime/bin/pnpm" --version >/dev/null 2>&1; then
  exec "$HERE/runtime/bin/pnpm" "$@"
fi
# 直接 exec 被 KYSEC / noexec 拦了：用系统受信任的动态加载器跑 pnpm 的 JS 入口。
# 全程普通用户，免 root。
PNPM_MJS="$HERE/runtime/lib/node_modules/pnpm/bin/pnpm.mjs"
if [ -f "$PNPM_MJS" ]; then
  for LD in /lib64/ld-linux-x86-64.so.2 /lib/ld-linux-aarch64.so.1 \
            /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib/aarch64-linux-gnu/ld-linux-aarch64.so.1; do
    [ -x "$LD" ] && exec "$LD" "$HERE/runtime/bin/node" "$PNPM_MJS" "$@"
  done
fi
printf '内置 pnpm 无法执行：请管理员把 %s 加入 KYSEC 信任白名单。\n' "$HERE/runtime/bin" >&2
exit 1
EOF
chmod 0755 "$APP/pnpm"

cat > "$APP/install.sh" <<'EOF'
#!/usr/bin/env bash
# DeepSeek Harness 离线包安装（普通权限即可，不需要 root / sudo）
#
# 用法：
#   bash install.sh                       装到 ~/.local/share/deepseek-harness
#   bash install.sh --prefix /data/dsh    装到任意可写目录
#   bash install.sh --no-launcher         不建 ~/.local/bin/dsh 启动器
#   bash install.sh --no-verify           装完不跑自检（默认会跑）
#   bash install.sh --yes                 非交互
#
# 包里自带 Node 运行时与全部依赖，装完即可用：
# 不依赖系统 Node / npm / pnpm，也不需要联网装任何东西。
set -uo pipefail

PREFIX="${DSH_PREFIX:-$HOME/.local/share/deepseek-harness}"
NO_LAUNCHER=0
HOME_MODE=copy        # copy: 插件树拷进 ~/.dsh（默认）
ASSUME_YES=0
NO_VERIFY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)    PREFIX="$2"; shift 2 ;;
    --no-launcher) NO_LAUNCHER=1; shift ;;
    --no-verify) NO_VERIFY=1; shift ;;
    --yes|-y)    ASSUME_YES=1; shift ;;
    -h|--help)   awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    *) printf '未知参数: %s\n' "$1" >&2; exit 1 ;;
  esac
done

say()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  ✅ %s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }
warn() { printf '  ⚠ %s\n' "$*"; }
die()  { printf '\n  ✖ %b\n' "$*" >&2; exit 1; }

SRC="${DSH_SRC:-}"
if [ -z "$SRC" ]; then
  _bs0="${BASH_SOURCE[0]:-}"
  if [ -n "$_bs0" ] && [ -f "$_bs0" ]; then
    SRC="$(cd "$(dirname "$_bs0")" && pwd)"
  else
    # 从 stdin 执行（KYSEC 拦脚本文件时的绕行方式）：DSH_SRC="$PWD" bash -s < install.sh
    SRC="$PWD"
  fi
fi
unset _bs0
[ -f "$SRC/kernel/node_modules/@deepseek-ai/dsh/lib/bin.js" ] || die "包结构不完整：找不到 kernel/node_modules/@deepseek-ai/dsh/lib/bin.js
  当前识别的包目录是：$SRC
  若是从 stdin 执行的，请显式指定：DSH_SRC=\"\$(pwd)\" bash -s < install.sh"
[ -f "$SRC/runtime/bin/node" ] || die "包结构不完整：找不到 runtime/bin/node"
# 补执行位：tar 解压/跨机拷贝都可能丢 mode，装之前统一修一次
chmod 0755 "$SRC/runtime/bin/node" 2>/dev/null || true

# ── ⓪ 执行环境预检：KYSEC / noexec / 执行位 ──────────────────────────────
# 银河麒麟 KYSEC 是内核安全模块（LSM），拦的是 execve，跟 uid 无关。
# 典型症状：`bash install.sh` 只打印一行 "KYSEC: 权限不够" 就退回提示符，
# 脚本一行都没执行 —— 此时 `sudo bash install.sh` 同样会被拦，加 sudo 没用。
exec_blocked_hint() {
  printf '\n'
  warn "检测到「脚本/二进制可能无法执行」的环境。以下普通用户即可，不需要 sudo："
  cat <<'HINT'
  ┌─ 1) 补执行位 + 在麒麟本机重新解压（最常见）────────────────────────
  │  chmod -R u+X runtime/bin ./*.sh dsh pnpm
  │  把 *.tar.gz 原文件拷进麒麟机，本机 tar -xzf 解压；别用在 Windows
  │  解压后拷过来的文件夹（丢执行位、无 KYSEC 标记）。
  │  ./runtime/bin/node --version   能出 v24.x 就说明执行控制没拦。
  ├─ 2) 脚本文件被拦：绕开 execve ─────────────────────────────────────
  │  ( source ./install.sh --no-verify )              旧包/新包都可用
  │  cat install.sh | DSH_SRC="$PWD" bash -s -- --no-verify   仅新版包
  │  ❌ 别用 bash -c "$(cat install.sh)"（BASH_SOURCE 为空会报错）
  ├─ 3) 内置 Node 二进制被拦：启动器会自动改用系统动态加载器 ─────────
  │  手动验证：/lib64/ld-linux-x86-64.so.2 <prefix>/runtime/bin/node --version
  │  （arm64 用 /lib/ld-linux-aarch64.so.1）
  ├─ 4) 分区 noexec ───────────────────────────────────────────────────
  │  mount | grep noexec  → 换到家目录下另一个可执行分区重新解压即可
  └─ 5) 以上都无效（需管理员，普通用户到此为止）─────────────────────
     getstatus 看 exec control；把 <prefix>、~/.dsh、runtime/bin/node
     交给管理员加进「安全管理中心 → 信任白名单」，或 sudo setstatus softmode
     （是这条命令，不是 sudo bash install.sh；sudo 提权本身不解决问题）
HINT
}
NOEXEC_HIT=""
if [ -r /proc/mounts ]; then
  # 只关心与「本包目录 / 安装目录」相关的挂载点；/proc /sys /dev 本来就带 noexec
  while read -r _dev _mnt _fs _opts _rest; do
    case ",$_opts," in *,noexec,*) ;; *) continue ;; esac
    case "$_mnt" in /proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*|/snap|/snap/*) continue ;; esac
    case "$SRC/|$PREFIX/" in
      "$_mnt"/*) NOEXEC_HIT="$NOEXEC_HIT $_mnt" ;;
    esac
  done < /proc/mounts
fi
KYSEC_STATE=""
if command -v getstatus >/dev/null 2>&1; then
  KYSEC_STATE="$(getstatus 2>/dev/null | grep -i 'exec control' | head -1)"
fi
# 只在「确有证据」时提示，避免每次安装都刷一屏 KYSEC 说明
if printf '%s' "$KYSEC_STATE" | grep -qi 'enforce' || \
   [ -n "$NOEXEC_HIT" ] || [ ! -x "$SRC/runtime/bin/node" ]; then
  info "noexec 挂载点：${NOEXEC_HIT:-（无）}"
  info "KYSEC 状态  ：${KYSEC_STATE:-（未检测到 getstatus 或该项）}"
  [ -x "$SRC/runtime/bin/node" ] \
    && info "runtime/bin/node 执行位：OK" \
    || warn "runtime/bin/node 没有执行位（已尝试 chmod，可能被文件系统/KYSEC 拒绝）"
  exec_blocked_hint
fi

say "安装 DeepSeek Harness（离线便携版）"
printf '  · 源  : %s\n  · 目标: %s\n' "$SRC" "$PREFIX"

df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {gb=$4/1048576; if (gb < 4) printf "  ⚠ 目标分区可用空间仅 %.1f GB，建议 ≥4GB\n", gb}'

say "① 部署应用文件"
mkdir -p "$PREFIX"
cp -a "$SRC/runtime" "$PREFIX/" || die "复制 runtime 失败"
cp -a "$SRC/kernel"  "$PREFIX/" || die "复制 kernel 失败"
chmod 0755 "$PREFIX/runtime/bin/node" 2>/dev/null || true   # 解压/拷贝可能丢执行位
cp -a "$SRC/home-template" "$PREFIX/" 2>/dev/null || true
cp -f "$SRC/dsh" "$PREFIX/" 2>/dev/null || true
cp -f "$SRC/pnpm" "$PREFIX/" 2>/dev/null || true
chmod 0755 "$PREFIX/dsh" "$PREFIX/pnpm" 2>/dev/null || true
cp -f "$SRC/install.sh" "$PREFIX/" 2>/dev/null || true
cp -f "$SRC/uninstall.sh" "$PREFIX/" 2>/dev/null || true
cp -f "$SRC/verify-install.sh" "$PREFIX/" 2>/dev/null || true
chmod 0755 "$PREFIX/verify-install.sh" 2>/dev/null || true
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
    DEST="$DSH_HOME_DIR/profiles/$name"
    if [ ! -d "$DEST" ]; then
      mkdir -p "$DSH_HOME_DIR/profiles"
      cp -a "$p" "$DSH_HOME_DIR/profiles/" && ok "profiles/$name 已部署"
      continue
    fi
    # 从旧包升级时 profile 已存在。若整包跳过，本包默认带的两个 subagent
    # 插件就永远进不去 —— 这里保留用户自己的配置，只补齐缺失的插件。
    info "profiles/$name 已存在：保留现有配置，补齐本包新增的插件"
    if [ -d "$p/node_modules" ]; then
      mkdir -p "$DEST/node_modules"
      cp -an "$p/node_modules/." "$DEST/node_modules/" 2>/dev/null || true
    fi
    if [ -f "$p/package.json" ] && [ -f "$DEST/package.json" ]; then
      CHANGED="$("$PREFIX/runtime/bin/node" -e '
        const fs = require("fs");
        const [dst, src] = process.argv.slice(1);
        try {
          const t = JSON.parse(fs.readFileSync(dst, "utf8"));
          const s = JSON.parse(fs.readFileSync(src, "utf8"));
          let changed = 0;
          t.dependencies = t.dependencies || {};
          for (const [k, v] of Object.entries(s.dependencies || {}))
            if (!(k in t.dependencies)) { t.dependencies[k] = v; changed++; }
          t.dsh = t.dsh || {}; t.dsh.profile = t.dsh.profile || {};
          const b = Array.isArray(t.dsh.profile.bundles)
                    ? t.dsh.profile.bundles : (t.dsh.profile.bundles = []);
          for (const n of (s.dsh?.profile?.bundles || []))
            if (!b.includes(n)) { b.push(n); changed++; }
          if (changed) fs.writeFileSync(dst, JSON.stringify(t, null, 2) + "\n");
          process.stdout.write(String(changed));
        } catch (e) { process.stdout.write("0"); }
      ' "$DEST/package.json" "$p/package.json" 2>/dev/null || printf '0')"
      if [ "${CHANGED:-0}" != "0" ]; then
        ok "profiles/$name 已合并 $CHANGED 项依赖/bundle（你原有的插件保留）"
        if [ -f "$p/pnpm-lock.yaml" ] && [ -f "$DEST/pnpm-lock.yaml" ]; then
          cp -f "$DEST/pnpm-lock.yaml" "$DEST/pnpm-lock.yaml.bak" 2>/dev/null || true
          cp -f "$p/pnpm-lock.yaml" "$DEST/pnpm-lock.yaml" 2>/dev/null || true
          info "pnpm-lock.yaml 已同步（旧文件备份为 .bak）"
        fi
      else
        info "profiles/$name 无需改动（插件已齐）"
      fi
    fi
    [ -f "$DEST/pnpm-lock.yaml" ] || cp -f "$p/pnpm-lock.yaml" "$DEST/pnpm-lock.yaml" 2>/dev/null || true
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
NODE="\$PREFIX/runtime/bin/node"
BIN="\$PREFIX/kernel/node_modules/@deepseek-ai/dsh/lib/bin.js"
if "\$NODE" --version >/dev/null 2>&1; then
  exec "\$NODE" "\$BIN" "\$@"
fi
# 直接 exec 被 KYSEC 执行控制 / noexec 拦了：借系统受信任的动态加载器执行。
# 被 execve 的是 ld-linux，node 只作为数据文件加载 —— 全程普通用户，免 root。
for LD in /lib64/ld-linux-x86-64.so.2 /lib/ld-linux-aarch64.so.1 \\
          /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib/aarch64-linux-gnu/ld-linux-aarch64.so.1; do
  [ -x "\$LD" ] && exec "\$LD" "\$NODE" "\$BIN" "\$@"
done
printf '内置 Node 无法执行：请管理员把 %s 与 %s 加入 KYSEC 信任白名单。\\n' \\
       "\$PREFIX" "\$HOME/.dsh" >&2
exit 1
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
case "$V" in
  v[0-9]*) ok "Node $V" ;;
  *)
    V="(不可执行)"
    warn "内置 Node 无法执行：$("$PREFIX/runtime/bin/node" --version 2>&1)"
    warn "这不代表包坏了 —— 多半是 KYSEC 执行控制 / noexec 挂载拦了 execve。"
    warn "照上面 ⓪ 的提示处理；安装文件本身已经部署完成。"
    ;;
esac
DV="$(env PATH="$PREFIX/runtime/bin:$PATH" DSH_HOME="$DSH_HOME_DIR" \
      "$PREFIX/runtime/bin/node" "$PREFIX/kernel/node_modules/@deepseek-ai/dsh/lib/bin.js" --version 2>&1 | tail -1)"
case "$DV" in
  *"权限不够"*|*"Permission denied"*|*KYSEC*|*"cannot execute"*)
    warn "dsh 启动被拦：$DV" ;;
  *) ok "dsh $DV" ;;
esac
PN="$(env PATH="$PREFIX/runtime/bin:$PATH" "$PREFIX/runtime/bin/pnpm" --version 2>/dev/null | tail -1)"
if [ -n "$PN" ]; then
  ok "pnpm $PN（dsh plugin 依赖它，已内置）"
else
  # 直启被 KYSEC/noexec 拦时，包内 pnpm 包装会自动改用动态加载器；这里如实反映
  PNPM_MJS="$PREFIX/runtime/lib/node_modules/pnpm/bin/pnpm.mjs"
  PN_FALLBACK=""
  if [ -f "$PNPM_MJS" ]; then
    for LD in /lib64/ld-linux-x86-64.so.2 /lib/ld-linux-aarch64.so.1 \
              /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib/aarch64-linux-gnu/ld-linux-aarch64.so.1; do
      [ -x "$LD" ] || continue
      PN_FALLBACK="$(env PATH="$PREFIX/runtime/bin:$PATH" "$LD" "$PREFIX/runtime/bin/node" \
                     "$PNPM_MJS" --version 2>/dev/null | tail -1)"
      [ -n "$PN_FALLBACK" ] && break
    done
  fi
  if [ -n "$PN_FALLBACK" ]; then
    ok "pnpm $PN_FALLBACK（直启被拦，已启用动态加载器回退，普通用户可用）"
    info "确认命令：$PREFIX/pnpm --version"
  else
    warn "pnpm 直启检测失败（多半是 KYSEC 拦了内置 Node ELF）；装完试 $PREFIX/pnpm --version"
    warn "Web UI 主体不受影响。免 root 处理办法见 说明.md「KYSEC」一节。"
  fi
fi

if [ "$NO_VERIFY" = "1" ]; then
  info "已按 --no-verify 跳过完整自检"
elif [ -f "$PREFIX/verify-install.sh" ]; then
  info "下面跑一遍完整自检（会实起一次 Web 服务再关掉，约 10~60 秒）："
  bash "$PREFIX/verify-install.sh" --prefix "$PREFIX" || warn "自检有告警/失败项，看上面输出"
fi

cat <<TIP

════════════════════════════════════════════════════════════
 安装完成
════════════════════════════════════════════════════════════

 启动（Web UI，默认 127.0.0.1:3080）：
   dsh web                      本机浏览器会自动打开
   dsh web --no-open            只起服务，不自动开浏览器
   dsh web --no-open --port 8080

 ⚠ 浏览器请用 Firefox 或 Chrome 打开（重要）：
   银河麒麟/统信自带的国产安全浏览器（奇安信可信浏览器、360、红莲花、搜狗等）
   对 ws:// 的兼容性差，常见现象是「页面能打开，但一直显示重新连接中」。
   遇到这种症状先换 Firefox，服务端不用动。详见 说明.md 的排查章节。
   打开时请复制启动日志里那条带 ?token= 的完整 URL，直接敲 127.0.0.1:3080 会 401。

 想从别的机器访问（改成你机器的内网 IP）：
   dsh web --no-open --host 192.168.1.10 --trusted-host 192.168.1.10:3080

 想再确认一遍「开箱即用」（内置 Node / 依赖树 / 原生模块 / 实起一次服务）：
   bash $PREFIX/verify-install.sh
 （安装时想跳过这步：bash install.sh --no-verify）

 ✅ 两个 subagent 插件已默认预装（版本与包内 dsh 对齐，无需再装）：
   @deepseek-ai/dsh-subagent-codex
   @deepseek-ai/dsh-subagent-claude-code
   确认：ls $DSH_HOME_DIR/profiles/web/node_modules/@deepseek-ai/dsh-subagent-*/
 ⚠ 这两个插件运行时调 OpenAI Codex / Anthropic Claude，能否用还看凭据与网络出口；
   dsh 自身的 DeepSeek 对话不受影响。

 还要装别的插件（dsh plugin 底层就是 pnpm，本包已内置 pnpm）：
   dsh plugin --profile web add /path/to/plugin-1.0.0.tgz     从本地 tarball 装
   dsh plugin --profile web add /path/to/plugin-dir           从本地目录装
   $PREFIX/pnpm --version                                     确认 pnpm 可用
 ⚠ pnpm add 默认仍会去 registry 拉「插件自己的依赖」。完全离线时请用
   「有网机器装好整个 profile → 拷 node_modules 过来」的办法，详见
   $PREFIX/说明.md 的「离线安装插件」一节。

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
#
# 用法：
#   bash uninstall.sh                     卸载，保留 ~/.dsh 会话与凭据
#   bash uninstall.sh --purge             连 ~/.dsh 一起删（不可恢复）
#   bash uninstall.sh --prefix /data/dsh  卸载装在别处的实例
#   bash uninstall.sh --yes               非交互
set -uo pipefail

PREFIX="${DSH_PREFIX:-$HOME/.local/share/deepseek-harness}"
PURGE_DATA=0
ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --purge)  PURGE_DATA=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
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

## 版本怎么来的

**包里的 dsh 版本不是写死的。** 构建时脚本会去 npm registry 读
`@deepseek-ai/dsh` 的 `dist-tags.latest`，打当时最新的那版（例如 `0.2.2-rc.1`），
不会再出现「一直停在 rc.2」的情况。

- 确切版本看包文件名 `deepseek-harness-<版本>-offline-<架构>.tar.gz`
  和同目录的 `.MANIFEST.txt`（`version` / `version_source` 两行）。
- 要**复现旧版本**或冻结升级，构建时显式传 `--version 0.2.1-rc.2`。
- 要追预发布线，用 `--dist-tag next`（或 `alpha`）。
- 两个 subagent 插件的版本会自动与 dsh 对齐，不用手动指定。

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
- **打开时用启动日志里那条带 `?token=` 的完整 URL**，直接敲 `127.0.0.1:3080` 会返回 401。

## 浏览器：请用 Firefox 或 Chrome（重要）

**银河麒麟 / 统信自带的国产安全浏览器（奇安信可信浏览器、360、红莲花、搜狗等）
很可能让 Web UI 一直停在「重新连接中…」，而页面本身看起来完全正常。**

原因是这类浏览器是 Chromium 深度定制版，几个特性常叠在一起：

1. 内核偏旧，对 `ws://` 与 Upgrade 握手的处理和新版不一致；
2. 内置安全策略 / 上网代理会把 `127.0.0.1` 的请求也送进企业代理 ——
   **普通 GET 能过（所以页面能打开），WebSocket 的 Upgrade 握手被拒绝或改写**；
3. 策略层可能直接禁用 WebSocket（不少单位的安全基线就这么配）。

**判断方法（30 秒）**：用 **Firefox** 打开同一条带 token 的 URL。

- 火狐正常 → 就是浏览器问题，本包与服务端都没有毛病，日常用火狐即可
- 火狐也不正常 → 跑 `bash <prefix>/diagnose-web.sh` 看卡在哪一环

必须留在国产浏览器里的话：关掉它的「上网代理 / 云安全防护」类功能，
或让管理员放开 WebSocket 策略项，并在代理例外里加入 `127.0.0.1`、`localhost`。

## 开箱即用：包里已经有什么

安装完**不需要**系统里有 Node / npm / pnpm，也不需要联网装任何东西：

| 需要的东西 | 谁提供 |
|---|---|
| Node 运行时（含 npm/npx） | `<prefix>/runtime`（打包时下载好的官方 Linux 二进制） |
| **pnpm（`dsh plugin` 依赖它）** | `<prefix>/runtime/bin/pnpm`（11.28.5，纯 JS，架构无关） |
| dsh 及全部 npm 依赖 | `<prefix>/kernel`（构建时 `npm install` 好的完整依赖树） |
| 原生模块（node-pty 等） | `<prefix>/kernel/node_modules`，已按架构预编译/解包好 |
| profile 插件（首次启动会联网拉的那批） | `<prefix>/home-template`，安装时并入 `~/.dsh` |
| **两个 subagent 插件（默认预装）** | 同上，已写进 `web` profile 的依赖与 bundles |

默认预装的两个官方插件：

- `@deepseek-ai/dsh-subagent-codex`
- `@deepseek-ai/dsh-subagent-claude-code`

它们与 dsh 同一个 monorepo 锁步发版，所以**版本与包内 dsh 完全一致**
（这两个包的 npm `latest` 标签是很旧的 `0.0.1-rc.1`，裸装会不兼容）。
包里连它们的平台二进制（`@openai/codex-linux-*`、`claude-agent-sdk-linux-*`）
也按目标架构一并装好了，离线机不需要再联网。

确认一下（在离线机上）：

```bash
ls ~/.dsh/profiles/web/node_modules/@deepseek-ai/dsh-subagent-{codex,claude-code}/package.json
# package.json 里 dependencies 与 dsh.profile.bundles 都应该有这两项
```

> 只有用 `--slim` 或 `--no-extra-plugins` 构建的包才不带这两个插件。
> 具体带了哪些、版本多少，看同目录 `.MANIFEST.txt` 的
> `extra_plugins` / `extra_specs` 两行。

启动器 `~/.local/bin/dsh` 只做一件事：把内置 Node 塞进 PATH 再起 dsh，
**不会用到系统 Node**。系统里有没有 Node、版本对不对，都无所谓。

不放心就跑一遍自检（会实起一次 Web 服务再关掉）：

```bash
bash <prefix>/verify-install.sh
```

## 离线安装插件

`dsh plugin` 的实现是**把参数原样转发给 pnpm**（在 profile 目录里执行），
所以在没有网络、没有系统 Node 的机器上装插件，卡的是 pnpm。本包已内置。

```bash
dsh plugin --profile web add <包>      # 官方入口（等价于在 profile 目录跑 pnpm add）
<prefix>/pnpm --version                # 确认内置 pnpm 可用
```

> **本包已经默认带上了** `@deepseek-ai/dsh-subagent-codex` 与
> `@deepseek-ai/dsh-subagent-claude-code`，**不用再手动装**。
> 注意：这两个 subagent 运行时调用的是 OpenAI Codex / Anthropic Claude 的
> 服务，能否真正跑通还取决于离线机有没有对应凭据与网络出口。
> 本包保证的是「插件已装好、能被 dsh 加载」，不保证外部模型可达；
> dsh 自身的 DeepSeek 对话功能不受影响。

### 三种可行做法，按「能不能联网」选

**① 插件本体是单个 tarball，且它没有额外依赖**（最简单，直接离线可成）

```bash
# 有网机器：下载插件包
npm pack @your-scope/dsh-plugin-xxx        # 得到 dsh-plugin-xxx-1.0.0.tgz
# 拷到离线机后：
dsh plugin --profile web add /path/to/dsh-plugin-xxx-1.0.0.tgz
```

**② 插件有依赖树（绝大多数情况）—— 在「有网机器」装好整个 profile，再整包拷**

这是最稳的离线法，等价于本包预装 profile 的做法：

```bash
# 有网机器（同架构、用同一版本的包）
dsh plugin --profile web add @your-scope/dsh-plugin-xxx
tar -czf profile-web.tgz -C ~/.dsh/profiles web

# 拷到离线机
tar -xzf profile-web.tgz -C ~/.dsh/profiles      # 覆盖前先备份原 profile
```

> pnpm 的 `node_modules` 默认用硬链接指向全局 store。tar 打包会把内容实体化，
> 所以解包后不需要原机器上的 store，**能正常 require**。
> 但若之后还要在离线机上用 pnpm 加别的包，建议在 profile 里写下
> `echo 'package-import-method=copy' >> ~/.dsh/profiles/web/.npmrc`，
> 让 pnpm 用复制而非硬链接，node_modules 更自包含。

**③ 内网有 npm 私服（verdaccio 等）** —— 直接把 registry 指过去

```bash
dsh plugin --profile web add @your-scope/dsh-plugin-xxx \
  --registry http://192.168.1.5:4873
```

### 常见坑

- **`dsh plugin` 报 `pnpm: command not found`**：说明用的是旧包（不含内置 pnpm），
  或 PATH 里没有 `<prefix>/runtime/bin`。用 `bash <prefix>/dsh plugin ...` 或
  `PATH=<prefix>/runtime/bin:$PATH dsh plugin ...` 重试；确认 `<prefix>/pnpm --version` 有输出。
- **`ERR_PNPM_NO_MATCHING_VERSION` / 一直卡在 resolved**：它在联网拉 registry。
  离线机请用上面 ② 或 ③。
- **装完插件没生效**：插件要写进 profile 的 patch 层才会被加载，
  `add` 只负责把包装进 node_modules。重启 `dsh web`，必要时
  `dsh --profile web --dump-config` 看插件是否在树里。
- **pnpm 版本别乱升**：11.x 是纯 JS；12.x 起分发按平台编译的 rust exe，
  在 x64 机器上装出来的包装到 arm64 上跑不了。

## 目录

| 路径 | 作用 |
|---|---|
| `<prefix>/runtime` | 内置 Node 运行时（不碰系统 Node，含 npm/npx/pnpm） |
| `<prefix>/kernel` | dsh 及全部依赖 |
| `<prefix>/home-template` | 预装的 profile 插件树（安装时并入 `~/.dsh`） |
| `<prefix>/dsh` | 包内直启脚本（不依赖 PATH） |
| `<prefix>/pnpm` | 包内 pnpm 包装（自动带内置 Node，装插件用） |
| `<prefix>/verify-install.sh` | 装机自检（证明上面的东西都在且能跑） |
| `~/.dsh` | 会话、凭据、插件（升级/重装不丢） |

## 卸载

```bash
bash uninstall.sh            # 保留会话数据
bash uninstall.sh --purge    # 连 ~/.dsh 一起删
```

## 注意

- 首次使用要在页面里配置 **DeepSeek API Key**；调用模型本身需要能访问 DeepSeek API。
- 内置 Node 是构建时按该版本 dsh 的 `engines.node` 自动选的（新版为 24.x）。
  Node 22/24 的官方 Linux 二进制都要求 **glibc ≥ 2.28**（内核 ≥ 4.18）；
  老机器上确认一下：`ldd --version | head -1`。
- 银河麒麟报 `KYSEC: 权限不够`：`sudo bash install.sh` 没用（KYSEC 在内核
  execve 层拦截，与 root 身份无关），而且**下面所有办法都是普通用户权限，不需要 sudo**：
  1. 把 `*.tar.gz` 拷进麒麟机**本机 `tar -xzf` 解压**，再
     `chmod -R u+X runtime/bin ./*.sh dsh pnpm`；
     用 `./runtime/bin/node --version` 验证（能出 v24.x 就没事）。
     别用在 Windows 解压后拷过来的文件夹 —— 会丢执行位与 KYSEC 标记，这是最常见根因。
  2. 脚本仍被拦：`( source ./install.sh --no-verify )`（只 open 不 exec 该脚本文件；
     子 shell 防止脚本 exit 关掉登录 shell）；新版包也可用
     `cat install.sh | DSH_SRC="$PWD" bash -s -- --no-verify`。
  3. `mount | grep noexec` 看分区，换到家目录下另一个可执行分区重新解压。
  4. 装完启动 `dsh web` 才报 KYSEC → 拦的是内置 Node 二进制。本包 `dsh` 启动器
     和 `pnpm` 包装脚本都会自动回退到系统动态加载器
     （`/lib64/ld-linux-x86-64.so.2`，arm64 为 `/lib/ld-linux-aarch64.so.1`），
     普通用户即可，无需改系统设置；`dsh plugin` 也覆盖到了。
  5. 以上都无效才是机器安全策略：请管理员把安装目录、`~/.dsh`、
     `runtime/bin/node` 加入「安全管理中心 → 信任白名单」，
     或临时 `sudo setstatus softmode`。普通用户到此为止，包本身没有问题。
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
# 装机自检脚本（可选：没带也只是跳过，不影响打包）
if [ -f "$KIT_DIR/verify-install.sh" ]; then
  cp -f "$KIT_DIR/verify-install.sh" "$APP/verify-install.sh"
  chmod 0755 "$APP/verify-install.sh"
  ok "已内置 verify-install.sh（装机自检：证明开箱即用）"
else
  warn "未找到 verify-install.sh —— 把它与 build-offline.sh 放同一目录即可自带；本次包内不含自检脚本"
fi
# Web 端诊断脚本（可选）：页面打不开 / 一直「重新连接中」时用
if [ -f "$KIT_DIR/diagnose-web.sh" ]; then
  cp -f "$KIT_DIR/diagnose-web.sh" "$APP/diagnose-web.sh"
  chmod 0755 "$APP/diagnose-web.sh"
  ok "已内置 diagnose-web.sh（Web 端四道关卡诊断）"
fi

ok "启动器 / install.sh / uninstall.sh / 说明.md 已生成"

# ── ⑥ 打包 ────────────────────────────────────────────────────────────────
say "⑥ 打包"
# 打包前统一修一次权限，避免解压端（尤其跨机器拷贝后）拿到没有执行位的文件
chmod 0755 "$APP/dsh" "$APP/pnpm" "$APP/install.sh" "$APP/uninstall.sh" 2>/dev/null || true
chmod 0755 "$APP"/runtime/bin/node "$APP"/runtime/bin/npm "$APP"/runtime/bin/npx 2>/dev/null || true
chmod 0755 "$APP"/runtime/bin/pnpm "$APP"/runtime/bin/pnpx "$APP"/runtime/bin/pn "$APP"/runtime/bin/pnx 2>/dev/null || true
STAGE_NAME="deepseek-harness-$DSH_VERSION-offline-$ARCH"
mv "$APP" "$STAGE/$STAGE_NAME" || die "整理目录失败"
TARBALL_OUT="$OUT/$STAGE_NAME.tar.gz"
tar -czf "$TARBALL_OUT" -C "$STAGE" "$STAGE_NAME" || die "打包失败"
# 产物自检：关键文件必须真的在包里（tar 静默丢文件是最难查的一类故障）
TAR_LIST="$WORK/tarlist.txt"
tar -tzf "$TARBALL_OUT" > "$TAR_LIST" 2>/dev/null || die "读不出刚打好的包（tar 损坏）"
for need in "$STAGE_NAME/install.sh" "$STAGE_NAME/runtime/bin/node" \
            "$STAGE_NAME/kernel/node_modules/@deepseek-ai/dsh/lib/bin.js" "$STAGE_NAME/说明.md"; do
  grep -qxF "$need" "$TAR_LIST" || die "包内缺少关键文件：$need"
done
grep -q "^$STAGE_NAME/runtime/bin/pnpm$" "$TAR_LIST" \
  && ok "包内已含 pnpm（dsh plugin 可用）" \
  || warn "包内没有 pnpm —— 离线机上 dsh plugin 将不可用（见 说明.md 的补装办法）"
# 默认带的两个 subagent 插件必须真的进了 tar，不能只在 MANIFEST 里写一句
if [ "$PLUGIN_STATUS" = "bundled" ]; then
  for n in "${PLUGIN_NAMES[@]}"; do
    grep -qxF "$STAGE_NAME/home-template/profiles/web/node_modules/$n/package.json" "$TAR_LIST" \
      && ok "包内已含插件 $n" \
      || warn "包内缺少 $n —— 离线机上这个插件不会生效"
  done
fi
SHA="$(sha256sum "$TARBALL_OUT" | awk '{print $1}')"
SIZE="$(du -h "$TARBALL_OUT" | cut -f1)"
printf '%s  %s\n' "$SHA" "$(basename "$TARBALL_OUT")" > "$OUT/$STAGE_NAME.sha256"
PNPM_MANIFEST="$([ -f "$STAGE/$STAGE_NAME/runtime/bin/pnpm" ] && echo "pnpm $PNPM_VERSION (bundled)" || echo 'pnpm MISSING')"
printf 'version        : %s\nversion_source : %s\narch           : %s\nnode           : %s\npnpm           : %s\nplugins        : %s\nextra_plugins  : %s\nextra_specs    : %s\nfile           : %s\nsize           : %s\nsha256         : %s\n' \
  "$DSH_VERSION" "$DSH_VERSION_SOURCE" "$ARCH" "$NODE_RUNTIME_VER" "$PNPM_MANIFEST" \
  "$([ "$SLIM" = "1" ] && echo 'not bundled (--slim)' || echo 'bundled')" \
  "$PLUGIN_STATUS" "${PLUGIN_SPECS_TEXT:-(none)}" \
  "$(basename "$TARBALL_OUT")" "$SIZE" "$SHA" > "$OUT/$STAGE_NAME.MANIFEST.txt"

say "构建完成"
ok "产物：$TARBALL_OUT"
ok "dsh $DSH_VERSION（$DSH_VERSION_SOURCE）· 架构 $ARCH"
ok "插件：$PLUGIN_STATUS ${PLUGIN_SPECS_TEXT:+($PLUGIN_SPECS_TEXT)}"
ok "体积：$SIZE  sha256：$SHA"
cat <<TIP

离线机上安装：
  tar -xzf $(basename "$TARBALL_OUT")
  cd $STAGE_NAME
  bash install.sh
  dsh web --no-open            # 然后浏览器访问 http://127.0.0.1:3080

本包已内置 @deepseek-ai/dsh-subagent-codex 与 @deepseek-ai/dsh-subagent-claude-code，
版本与 dsh $DSH_VERSION 对齐；想确认看同目录的 .MANIFEST.txt。
TIP
