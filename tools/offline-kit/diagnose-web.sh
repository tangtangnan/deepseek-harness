#!/usr/bin/env bash
# DeepSeek Harness Web 端「重新连接中…」诊断（只读，不改任何东西）
#
# 用法：
#   bash diagnose-web.sh                    # 自动探测安装目录
#   bash diagnose-web.sh --prefix /data/dsh
#   bash diagnose-web.sh --port 3081        # 换端口（默认 3080）
#   bash diagnose-web.sh --kill-stale       # 先结束占着端口的残留 dsh 进程再诊断
#   bash diagnose-web.sh --fresh-home       # 换全新临时数据目录启动（排除插件/profile 问题）
#   bash diagnose-web.sh --keep             # 诊断完保留服务进程
#
# 它做什么：
#   ⓪ 环境自检 + 代理检查 + PATH 里 dsh 与本安装目录的一致性
#   ① 端口预检（残留 dsh 进程占端口是新实例启动失败的头号原因），再起一次 dsh web
#   ② 用 curl 依次验证 首页 / token 登录 / cookie / WebSocket 握手
#   ③ 指出「重新连接中」卡在四道关卡的哪一道：
#      Host 校验(403) → cookie 鉴权(401) → peer 占用(409) → ws 路由未注册(直接断)
#   ④ 用包内自带的 ws 模块真连一次，发 Ping 看有没有 Pong（判通道双向活性）
#      注意：dsh 的 mux 是纯被动响应式，服务端不主动发业务帧是正常的，
#      靠"数数据帧"判断死活会误报（早期版本踩过）
#   ⑤ 把插件加载报错、原生模块报错单独拎出来；启动失败时附上 ~/.dsh/logs 的详细诊断
#   ⑥ 端口连接与对端进程（会认出奇安信/360 等国产安全浏览器并告警）
#
# 退出码：0 全部正常 / 1 发现问题（看最后一节「结论」）
set -uo pipefail

PREFIX="${DSH_PREFIX:-}"
PORT=3080
KEEP=0
KILL_STALE=0
FRESH_HOME=0

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --port)   PORT="$2"; shift 2 ;;
    --keep)   KEEP=1; shift ;;
    --kill-stale) KILL_STALE=1; shift ;;
    --fresh-home) FRESH_HOME=1; shift ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    *) printf '未知参数: %s\n' "$1" >&2; exit 1 ;;
  esac
done

say()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✅\033[0m %s\n' "$*"; }
no()   { printf '  \033[31m✘\033[0m %s\n' "$*"; }
wn()   { printf '  \033[33m⚠\033[0m %s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }

# ── ⓪ 定位 ────────────────────────────────────────────────────────────────
# 候选顺序：显式 --prefix → 默认安装位置 → 当前目录（解压后直接用的情况）→ 家目录下的解压目录
# 注意中文 locale 的家目录叫「下载/桌面」，英文叫 Downloads/Desktop，两边都要扫；
# 同时排除上一代 Electron 项目的 deepseek-harness-desktop-*（结构不同，不是这套包）
candidates() {
  printf '%s\n' "$HOME/.local/share/deepseek-harness"
  printf '%s\n' "/opt/deepseek-harness"
  printf '%s\n' "$PWD"
  for d in \
    "$HOME"/deepseek-harness-*-offline-* \
    "$HOME"/下载/deepseek-harness-*-offline-* \
    "$HOME"/Downloads/deepseek-harness-*-offline-* \
    "$HOME"/桌面/deepseek-harness-*-offline-* \
    "$HOME"/Desktop/deepseek-harness-*-offline-*; do
    case "$d" in *desktop*) continue ;; esac
    [ -d "$d" ] && printf '%s\n' "$d"
  done
}

if [ -z "$PREFIX" ]; then
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if [ -x "$c/runtime/bin/node" ]; then PREFIX="$c"; break; fi
  done <<EOF
$(candidates)
EOF
fi
PREFIX="${PREFIX%/}"

# 用户显式指定（或自动探测到的）目录，逐项说清楚是「不存在」还是「缺执行位」
if [ -n "$PREFIX" ] && [ ! -x "$PREFIX/runtime/bin/node" ]; then
  if [ -e "$PREFIX/runtime/bin/node" ]; then
    no "runtime/bin/node 【存在但没有执行位】—— 这正是安装时『权限不够』的同一个原因"
    info "路径：$PREFIX/runtime/bin/node"
    info "文件的权限是：$(ls -l "$PREFIX/runtime/bin/node" 2>/dev/null | awk '{print $1}')"
    info "修复：  chmod -R 0755 \"$PREFIX/runtime/bin\""
    info "然后重跑本脚本。"
  else
    no "目录里没有 runtime/bin/node：$PREFIX"
    info "这不像一个安装目录，也可能是个空壳解压目录。"
  fi
  info ""
  info "可用安装目录候选（自动扫描结果）："
  FOUND=0
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if [ -e "$c/runtime/bin/node" ]; then
      MARK="-x"; [ -x "$c/runtime/bin/node" ] || MARK="无执行位"
      printf '    %s  %s\n' "$MARK" "$c"
      FOUND=1
    fi
  done <<EOF
$(candidates)
EOF
  [ "$FOUND" = "0" ] && printf '    （没有找到任何含 runtime/bin/node 的目录）\n'
  info ""
  info "若还没安装，先进解压目录执行：bash install.sh"
  info "若已装到别处：bash diagnose-web.sh --prefix <安装目录>"
  exit 1
fi
if [ -z "$PREFIX" ]; then
  no "找不到安装目录"
  info "可用目录候选："
  while IFS= read -r c; do [ -d "$c" ] && printf '    %s\n' "$c"; done <<EOF
$(candidates)
EOF
  info "试试：bash diagnose-web.sh --prefix <安装目录>"
  exit 1
fi
NODE="$PREFIX/runtime/bin/node"
BIN="$PREFIX/kernel/node_modules/@deepseek-ai/dsh/lib/bin.js"

# DSH_HOME：默认用你的用户数据目录；--fresh-home 换成全新的临时目录，
# 用来把「插件/profile 数据有问题」和「dsh 本身有问题」彻底分开。
if [ "$FRESH_HOME" = "1" ]; then
  DSH_HOME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dsh-fresh-XXXXXX")"
else
  DSH_HOME_DIR="${DSH_HOME:-$HOME/.dsh}"
fi

say "⓪ 环境"
info "安装目录：$PREFIX"
info "数据目录：$DSH_HOME_DIR $([ "$FRESH_HOME" = "1" ] && echo '（全新临时目录，不加载现有 profiles/凭据）')"
if [ "$FRESH_HOME" != "1" ] && [ -d "$DSH_HOME_DIR/profiles" ]; then
  PROF_LIST="$(ls -1 "$DSH_HOME_DIR/profiles" 2>/dev/null | tr '\n' ' ')"
  info "已装 profile：${PROF_LIST:-（空）}"
  for p in $PROF_LIST; do
    [ -d "$DSH_HOME_DIR/profiles/$p/node_modules" ] \
      && info "  $p：$(ls -1 "$DSH_HOME_DIR/profiles/$p/node_modules" 2>/dev/null | wc -l | tr -d ' ') 个包" \
      || wn "  $p：没有 node_modules（插件树不完整 —— 离线启动时拉不到插件会导致功能缺失）"
  done
fi
info "Node     ：$($NODE --version 2>&1)"

# 关键：用户手动敲的 `dsh` 可能来自另一个安装（甚至上一代 dsh-desktop 项目），
# 那诊断结论就会与实际现象对不上。这里把它揪出来。
DSH_IN_PATH="$(command -v dsh 2>/dev/null || true)"
if [ -n "$DSH_IN_PATH" ]; then
  info "PATH 里的 dsh：$DSH_IN_PATH"
  REAL_DSH="$(readlink -f "$DSH_IN_PATH" 2>/dev/null || printf '%s' "$DSH_IN_PATH")"
  [ "$REAL_DSH" != "$DSH_IN_PATH" ] && info "  → 实际文件：$REAL_DSH"
  LAUNCHER_TEXT="$(head -40 "$DSH_IN_PATH" 2>/dev/null || true)"
  if printf '%s' "$LAUNCHER_TEXT" | grep -qF "$PREFIX"; then
    ok "与本次诊断的安装目录一致"
  else
    wn "这个 dsh 【不是】当前诊断的安装目录启动的！"
    info "它实际调用的路径大致是："
    printf '%s\n' "$LAUNCHER_TEXT" | grep -E '^[[:space:]]*(exec|HERE=|PREFIX=|DIR=|export)' \
      | head -4 | sed 's/^/      /'
    info "你在终端里敲 dsh web 起的可能是另一个版本的 dsh —— 这会让诊断结论对不上。"
    info "请改用这个安装目录自己的启动器："
    info "    $PREFIX/dsh web --no-open        （包内直启，数据落 $PREFIX/home）"
  fi
else
  wn "PATH 里没有 dsh 命令（可能 ~/.local/bin 未加入 PATH）"
fi
info "dsh      ：$(env PATH="$PREFIX/runtime/bin:$PATH" DSH_HOME="$DSH_HOME_DIR" \
        "$NODE" "$BIN" --version 2>&1 | tail -1)"
info "架构     ：$(uname -m)"
info "内核     ：$(uname -r)"

# 代理是「页面能开、ws 死活连不上」的高频原因，先看一眼
PROXY_ENV="$(env | grep -iE '^(http|https|all|ftp)_proxy=' | tr '\n' ' ')"
GS_PROXY="$(gsettings get org.gnome.system.proxy mode 2>/dev/null | tr -d "'" || echo '')"
if [ -n "$PROXY_ENV" ] || { [ -n "$GS_PROXY" ] && [ "$GS_PROXY" != "none" ]; }; then
  wn "检测到代理配置：${PROXY_ENV:-}(桌面代理模式：${GS_PROXY:-未知})"
  info "浏览器走代理时 ws://127.0.0.1 也常被拦 —— 本脚本已用 --noproxy 绕过代理直连测试"
fi

LOG="${TMPDIR:-/tmp}/dsh-diag-$$.log"
say "① 启动 dsh web（日志：$LOG）"

# 端口预检：残留的 dsh 进程占着端口时，新进程会 EADDRINUSE 直接失败，
# 表现为「webServer 没激活 → 一串插件等它 → appReady 永不 commit」。
if command -v ss >/dev/null 2>&1; then
  OCCUPIED="$(ss -ltnp 2>/dev/null | grep ":$PORT " || true)"
  if [ -n "$OCCUPIED" ]; then
    wn "端口 $PORT 已被占用："
    printf '%s\n' "$OCCUPIED" | sed 's/^/    /'
    STALE_PIDS=""
    for p in $(printf '%s\n' "$OCCUPIED" | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u); do
      CMDLINE="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || echo '')"
      case "$CMDLINE" in
        *dsh*|*deepseek-harness*)
          STALE_PIDS="$STALE_PIDS $p"
          info "PID $p 是 dsh 进程（残留）：$(printf '%s' "$CMDLINE" | cut -c1-100)"
          ;;
        *) info "PID $p 不是 dsh：$(printf '%s' "$CMDLINE" | cut -c1-100)" ;;
      esac
    done
    if [ -n "$STALE_PIDS" ]; then
      if [ "$KILL_STALE" = "1" ]; then
        info "按 --kill-stale 结束残留进程：$STALE_PIDS"
        kill $STALE_PIDS 2>/dev/null || true
        sleep 2
        kill -9 $STALE_PIDS 2>/dev/null || true
        sleep 1
      else
        no "这就是之前「页面能开但一直重新连接中」的常见原因之一"
        info "先结束它再诊断：  kill$STALE_PIDS"
        info "或直接重跑本脚本并加 --kill-stale 自动处理"
        exit 1
      fi
    fi
  else
    info "端口 $PORT 空闲"
  fi
fi
env PATH="$PREFIX/runtime/bin:$PATH" DSH_HOME="$DSH_HOME_DIR" \
    "$NODE" "$BIN" web --no-open --port "$PORT" > "$LOG" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT

TOKEN_URL=""
STARTUP_FAILED=0
for i in $(seq 1 40); do
  TOKEN_URL="$(grep -o "http://[0-9.]*:[0-9]\{2,5\}/?token=[A-Za-z0-9_-]\{20,\}" "$LOG" 2>/dev/null | head -1)"
  [ -n "$TOKEN_URL" ] && break
  # 启动失败要立刻报，别干等满 40 秒
  if grep -qE "startup failed|did not activate|EADDRINUSE" "$LOG" 2>/dev/null; then
    STARTUP_FAILED=1; break
  fi
  kill -0 "$PID" 2>/dev/null || break
  sleep 1
done
if [ -z "$TOKEN_URL" ]; then
  if [ "$STARTUP_FAILED" = "1" ]; then
    no "dsh 启动失败（插件没全部激活）—— 日志如下"
  else
    no "40 秒内没等到 dsh 打印 token URL —— 服务没起来，看下面日志"
  fi
  printf '\n---------- 日志全文 ----------\n'; cat "$LOG"; printf -- '------------------------------\n'

  # 按已知模式给结论，不用用户自己猜
  if grep -q "EADDRINUSE" "$LOG" 2>/dev/null; then
    echo
    no "端口 $PORT 被别的进程占着（EADDRINUSE）"
    info "这是「页面能开、但一直重新连接中」的典型半边：旧进程占住端口，"
    info "新实例的 webServer 插件激活失败 → 依赖它的插件全部等不到服务 → ws 路由不注册。"
    info "处理：先结束旧进程，再重跑本脚本加 --kill-stale"
    if command -v ss >/dev/null 2>&1; then
      info "当前占用者：$(ss -ltnp 2>/dev/null | grep ":$PORT " || echo '（已释放）')"
    fi
  elif grep -q "did not activate" "$LOG" 2>/dev/null; then
    no "有 required 插件未激活 —— 上面的 Failed plugins 里就是原因"
  fi

  # dsh 会把完整启动诊断写到 ~/.dsh/logs/，比 stdout 详细得多
  DSH_LOGS="$(find "$DSH_HOME_DIR/logs" -maxdepth 1 -name 'startup-*.log' -printf '%T@ %p\n' 2>/dev/null \
              | sort -rn | head -1 | cut -d' ' -f2-)"
  if [ -n "$DSH_LOGS" ]; then
    echo
    info "dsh 自己的启动诊断（更详细）：$DSH_LOGS"
    info "最后 30 行："
    tail -30 "$DSH_LOGS" 2>/dev/null | sed 's/^/    /'
  fi
  exit 1
fi
ok "服务已就绪"
info "token URL：$(printf '%s' "$TOKEN_URL" | sed 's/token=.*/token=<hidden>/')"
# 给 appReady / 插件初始化留点时间（ws 路由要等它才注册）
sleep 8

BASE="http://127.0.0.1:$PORT"
JAR="${TMPDIR:-/tmp}/dsh-diag-cookie-$$.txt"
rm -f "$JAR"

say "② HTTP 关卡"

# 不带 cookie 访问首页
CODE_NOCOOKIE="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 8 "$BASE/" 2>/dev/null || true)"
info "GET /            （无 cookie） → HTTP $CODE_NOCOOKIE"
[ "$CODE_NOCOOKIE" = "401" ] && ok "401 = 鉴权正常工作（这是设计，不是故障）"

# 用 token URL 登录，收 cookie
CODE_TOKEN="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 8 -c "$JAR" "$TOKEN_URL" 2>/dev/null || true)"
info "GET /?token=...  （登录）     → HTTP $CODE_TOKEN"
COOKIES="$(awk 'NF>=7 && $0 !~ /^#( |$)/ {print $6}' "$JAR" 2>/dev/null | tr '\n' ' ')"
if [ -z "${COOKIES// /}" ]; then
  COOKIES="$(awk 'NF>=7 {print $6}' "$JAR" 2>/dev/null | tr '\n' ' ')"
fi
if [ -n "${COOKIES// /}" ]; then
  ok "已下发 cookie：$COOKIES"
else
  no "没有下发任何 cookie —— 浏览器因此无法通过 ws 鉴权"
fi

# 带 cookie 访问首页
CODE_AUTH="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 8 -b "$JAR" "$BASE/" 2>/dev/null || true)"
info "GET /            （带 cookie） → HTTP $CODE_AUTH"
[ "$CODE_AUTH" = "200" ] && ok "cookie 有效" || no "cookie 无效（HTTP $CODE_AUTH）"

say "③ WebSocket 关卡（决定『重新连接中』）"
# 1) 带 cookie 握手
WS_BODY="${TMPDIR:-/tmp}/dsh-diag-ws-$$.txt"
curl -s --noproxy '*' -i -N --max-time 6 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  -H "Origin: $BASE" -b "$JAR" \
  "$BASE/api/remote.mux" > "$WS_BODY" 2>/dev/null
WS_LINE="$(head -1 "$WS_BODY" 2>/dev/null | tr -d '\r')"
info "带 cookie  → ${WS_LINE:-（无响应，连接被直接断开）}"
WS_CODE="$(printf '%s' "$WS_LINE" | awk '{print $2}')"

# 2) 不带 cookie 握手（对照组：若这里也是 101 说明鉴权没生效）
WS_BODY2="${TMPDIR:-/tmp}/dsh-diag-ws2-$$.txt"
curl -s --noproxy '*' -i -N --max-time 6 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  -H "Origin: $BASE" \
  "$BASE/api/remote.mux" > "$WS_BODY2" 2>/dev/null
info "不带 cookie → $(head -1 "$WS_BODY2" 2>/dev/null | tr -d '\r' || echo '（无响应）')"

case "$WS_CODE" in
  101) ok "WebSocket 握手成功 —— 服务端这条路是通的，问题在浏览器侧（cookie / 代理 / 旧页面）";;
  401) no "401 Unauthorized —— cookie 没被服务端认（可能浏览器没带，或 cookie 已失效）";;
  403) no "403 Forbidden —— Host/Origin 被 trusted-host 拦了";;
  409) no "409 Conflict —— 这条 peer 已被别的 socket 占用（多半是上一次没退干净的进程）";;
  "")  no "没有任何 HTTP 响应，socket 被直接断开 —— 典型是 /api/remote.mux 的 ws 路由【还没注册】"
       info "路由要等 appReady 就绪后才注册；appReady 卡住通常是插件初始化失败，看下一节日志";;
  *)   no "意外的握手响应：$WS_LINE";;
esac

say "④ WebSocket 通道探测（握手成功 ≠ 通道可用）"
# 重要：dsh 的 mux 是【纯被动响应式】——服务端的 run() 只在收到客户端 open 帧时才开流回数据，
# 连上后不发任何业务帧是正常设计。所以不能靠"数数据帧"判断后端死活（会误报）。
# 正确的活性判据：OPEN 后主动发 WebSocket Ping，收到 Pong 即证明链路双向健康。
COOKIE_PAIR="$(awk 'NF>=7 && $0 !~ /^#( |$)/ {print $6"="$7; exit}' "$JAR" 2>/dev/null)"
[ -z "$COOKIE_PAIR" ] && COOKIE_PAIR="$(awk 'NF>=7 {print $6"="$7; exit}' "$JAR" 2>/dev/null)"
if [ -d "$PREFIX/kernel/node_modules/ws" ] && [ -n "$COOKIE_PAIR" ]; then
  PROBE="${TMPDIR:-/tmp}/dsh-wsprobe-$$.js"
  cat > "$PROBE" <<'JSEOF'
const [, , url, cookie] = process.argv
const WebSocket = require('ws')
let frames = 0
let ponged = false
let done = false
const ws = new WebSocket(url, { headers: { Cookie: cookie } })
const finish = () => {
  if (done) return
  done = true
  console.log('FRAMES ' + frames)
  console.log(ponged ? 'PONG ok' : 'PONG none')
  process.exit(0)
}
ws.on('open', () => {
  console.log('OPEN')
  try { ws.ping() } catch (e) { console.log('PINGFAIL ' + e.message) }
})
ws.on('pong', () => { ponged = true; console.log('PONG'); setTimeout(finish, 120) })
ws.on('message', (d) => { frames += 1; if (frames <= 3) console.log('MSG ' + String(d).slice(0, 140)) })
ws.on('error', (e) => { console.log('ERROR ' + e.message); finish() })
ws.on('close', (c, r) => { console.log('CLOSE ' + String(c) + ' ' + String(r)); finish() })
setTimeout(finish, 4000)
JSEOF
  info "用内置 node + ws 模块真连 /api/remote.mux（Ping/Pong 验活性，4 秒）"
  PROBE_OUT="$(NODE_PATH="$PREFIX/kernel/node_modules" "$NODE" "$PROBE" \
      "ws://127.0.0.1:$PORT/api/remote.mux" "$COOKIE_PAIR" 2>&1)"
  printf '%s\n' "$PROBE_OUT" | head -6 | sed 's/^/    /'
  PROBE_FRAMES="$(printf '%s\n' "$PROBE_OUT" | awk '/^FRAMES /{print $2}')"
  case "$PROBE_OUT" in
    *PONG\ ok*)
      ok "通道双向健康（PING → PONG 正常）—— 服务端完全没问题"
      [ "${PROBE_FRAMES:-0}" -gt 0 ] && info "另外收到 $PROBE_FRAMES 个业务帧"
      info "服务端纯被动：不发帧是正常的，只要 PONG 有回就说明这条 ws 通路是活的"
      ;;
    *OPEN*)
      no "握手成功、Ping 无回（4 秒内没收到 Pong）—— 链路被中间设备单向吞了"
      info "常见于企业上网代理/安全网关对 127.0.0.1 的 Upgrade 流量做改写。"
      info "非浏览器客户端受影响 = 不是浏览器兼容性问题，查本机代理配置（http_proxy 等）。"
      ;;
    *CLOSE*|*ERROR*)
      no "连上后被立即断开 / 报错 —— 看上面那一行的具体原因"
      ;;
    *)
      no "没能建立连接，输出如上"
      ;;
  esac
  rm -f "$PROBE"
else
  wn "跳过（包内没有 ws 模块，或没拿到 cookie）"
fi

say "⑤ 日志里的异常（插件 / 原生模块 / 崩溃）"
PAT='error|Error|ERROR|warn|Warning|failed|Failed|不了|失败|skipping|incompatible|cannot|not found|Cannot|权限'
HITS="$(grep -nE "$PAT" "$LOG" 2>/dev/null | grep -viE 'deprecat|experimental' | head -40)"
if [ -n "$HITS" ]; then
  printf '%s\n' "$HITS" | sed 's/^/    /'
else
  ok "日志里没有明显的错误行"
fi

say "⑥ 进程与端口"
info "PID $PID：$(kill -0 "$PID" 2>/dev/null && echo 存活 || echo 已退出)"
if command -v ss >/dev/null 2>&1; then
  CONN="$(ss -tnp 2>/dev/null | grep ":$PORT" | head -10)"
  if [ -n "$CONN" ]; then
    printf '%s\n' "$CONN" | sed 's/^/    /'
    # 认出客户端是哪家浏览器 —— 国产安全浏览器是「服务端全绿但前端连不上」的常见元凶
    CLIENT_PROCS="$(printf '%s\n' "$CONN" | grep -o 'users:(("[^"]*"' | sed 's/.*("//; s/"$//' | sort -u | tr '\n' ' ')"
    [ -n "$CLIENT_PROCS" ] && info "对端进程：$CLIENT_PROCS"
    case "$CLIENT_PROCS" in
      *qaxbrowser*|*360*|*qqbrowser*|*uosbrowser*|*redflag*|*sogou*|*maxthon*)
        wn "检测到国产安全浏览器 —— 内核偏旧或有企业安全策略"
        info "这类浏览器既可能直接拦掉 ws://127.0.0.1，也可能因 JS 特性不兼容让前端连接模块挂掉"
        info "（两种表现都是「页面能开 + 永远重新连接中」）。请务必用 Firefox / 系统 Chrome 对照一次。"
        ;;
    esac
  else
    info "当前没有任何到 $PORT 的连接（浏览器可能还没打开页面）"
  fi
fi

say "结论"
RC=0
if [ "$WS_CODE" = "101" ]; then
  printf '  服务端一切正常（ws 握手 101、鉴权 401 对照也正确）。\n'
  printf '  那么卡在浏览器的概率极高。会话 cookie（dsh-auth-<authority 的 hash>，\n'
  printf '  HttpOnly + SameSite=Strict）用持久密钥签名，正常情况下重启 dsh 依然有效；\n'
  printf '  但以下情况会让它彻底对不上 → ws 一直 401 → 前端无限「重新连接中」：\n'
  printf '    · ~/.dsh 里的凭据被重建过（重装 / uninstall --purge / 删过数据目录）\n'
  printf '    · 曾用 localhost 登录，现在用 127.0.0.1（或反过来 / 换过内网 IP）——\n'
  printf '      cookie 名按 authority 算，换写法就是另一个 cookie\n'
  printf '    · cookie 超过有效期，或浏览器隐私策略拦掉了它\n\n'
  printf '  按这个顺序试（越靠前越省事）：\n'
  printf '    1) ★★ 先换浏览器对照 —— 如果你用的是国产安全浏览器\n'
  printf '       （奇安信/360/红莲花/统信/搜狗/QQ 等，麒麟 V10 自带的就是这类），\n'
  printf '       直接换 Firefox 打开同一条带 ?token= 的 URL。这类浏览器是 Chromium 深度定制：\n'
  printf '         · 内核偏旧，对 ws:// 和 Upgrade 的处理与新版不一致\n'
  printf '         · 内置安全策略/上网代理会把 127.0.0.1 也送进企业代理，\n'
  printf '           普通 GET 能过（所以页面能开），Upgrade 握手被拒或被改写\n'
  printf '         · 策略层甚至直接禁用 WebSocket（不少单位的安全基线就这么配）\n'
  printf '       【实测结论：麒麟上这类问题换 FireFox 即恢复，服务端本身没毛病】\n'
  printf '    2) 开一个【无痕/隐私窗口】，打开本次启动打印的那条带 ?token= 的完整 URL\n'
  printf '       （无痕窗口没有旧 cookie，最干净）\n'
  printf '    3) 普通窗口：F12 → Application → Storage → Cookies → %s\n' "$BASE"
  printf '       → 把 dsh-auth-* 全部删除，然后用新的 token URL 重新打开\n'
  printf '    4) 一定要打带 ?token=... 的那条，别直接敲 %s\n' "$BASE"
  printf '    5) 访问地址前后要一致：一直用 127.0.0.1 就别中途换 localhost / 内网 IP\n'
  printf '    6) 用内网 IP 访问的场景：dsh web 要 --host <IP>，且 --trusted-host 必须包含 IP:端口\n'
  printf '    7) 检查系统代理 / VPN —— ws://127.0.0.1 常被代理拦（把 127.0.0.1 加进忽略列表）\n'
  printf '    8) 不想换浏览器：关掉它的「上网代理 / 云安全防护」，或让管理员放开 WebSocket 策略\n'
  printf '\n  想直接拿一条可点的完整 token URL 并保留服务：\n'
  printf '      bash %s --keep\n' "$(basename "$0")"
elif [ -z "$WS_CODE" ]; then
  printf '  ws 路由未注册 —— 服务端初始化没走完。把本脚本输出的【全部内容】发我，\n'
  printf '  重点看 ④ 里第一条 error（插件名 + 原因）。\n'
  RC=1
else
  printf '  ws 握手被拒（%s）—— 把本脚本输出的【全部内容】发我。\n' "$WS_CODE"
  RC=1
fi
printf '\n  完整日志已保存在：%s\n' "$LOG"

if [ "$KEEP" = "1" ]; then
  trap - EXIT
  printf '\n  服务保留中（PID %s）：浏览器打开 %s\n' "$PID" "$TOKEN_URL"
else
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
fi
exit $RC
