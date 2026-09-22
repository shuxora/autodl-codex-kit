#!/usr/bin/env bash
# ============================================================================
# 开机启动脚本 —— 拉起 Xray 代理（幂等，可重复执行）
#
#   bash /root/startup.sh          正常输出
#   bash /root/startup.sh -q       静默模式（供 .bashrc 调用）
#   bash /root/startup.sh -n       不等待就绪（用于 shell 启动，避免卡住）
#   bash /root/startup.sh -u       先更新订阅再启动
#
# 开机自动执行路径：/init/bin/customer.cmd.sh -> /etc/autodl.sh -> 本脚本
# ============================================================================
set -u

XRAY_DIR="${XRAY_DIR:-/root/autodl-tmp/xray-core}"
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
CONFIG="$XRAY_DIR/config.json"
XRAY_LOG="$XRAY_DIR/xray.log"
RUN_LOG="$XRAY_DIR/startup.log"
LOCK="$XRAY_DIR/.startup.lock"
HTTP_ADDR=127.0.0.1:10809
NODE_PY="${XRAY_NODE_PY:-/root/xray-node.py}"

QUIET=0
NOWAIT=0
UPDATE=0
for a in "$@"; do
    case "$a" in
        -q|--quiet)   QUIET=1 ;;
        -n|--no-wait) NOWAIT=1 ;;
        -u|--update)  UPDATE=1 ;;
    esac
done

log()  { [ "$QUIET" -eq 1 ] || echo "[startup] $*"; }
logf() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$RUN_LOG"; }

mkdir -p "$XRAY_DIR"

# --- 串行化：多个终端同时打开时只跑一次 --------------------------------------
exec 9>"$LOCK"
if ! flock -n 9; then
    log "另一启动流程进行中，跳过。"
    exit 0
fi

# --- 已在运行则直接退出 ------------------------------------------------------
if pgrep -f "$XRAY_BIN run" >/dev/null 2>&1; then
    log "xray 已在运行 (PID $(pgrep -f "$XRAY_BIN run" | head -1))，无需操作。"
    exit 0
fi

# --- 前置检查 ----------------------------------------------------------------
if [ ! -x "$XRAY_BIN" ]; then
    log "错误：找不到可执行文件 $XRAY_BIN"
    logf "错误：找不到 $XRAY_BIN"
    exit 1
fi
if [ ! -f "$CONFIG" ]; then
    log "错误：找不到配置文件 $CONFIG"
    logf "错误：找不到 $CONFIG"
    exit 1
fi

# --- 等待容器网络就绪 --------------------------------------------------------
if [ "$NOWAIT" -eq 0 ]; then
    ok=0
    for _ in $(seq 1 30); do
        # --noproxy '*' 很关键：忽略环境里残留的 http_proxy，否则会走还没起来的代理而误判
        if curl -s -o /dev/null --max-time 3 --noproxy '*' http://www.baidu.com/ 2>/dev/null; then
            ok=1; break
        fi
        sleep 2
    done
    [ "$ok" -eq 1 ] && log "网络已就绪。" || log "警告：网络检测超时，仍然尝试启动。"
fi

# --- 可选：更新订阅 ----------------------------------------------------------
if [ "$UPDATE" -eq 1 ] && [ -f "$NODE_PY" ]; then
    log "更新订阅中..."
    if out=$(python3 "$NODE_PY" --update-only 2>&1); then
        log "$out"
    else
        log "订阅更新失败，继续使用本地缓存。"
    fi
fi

# --- 启动 xray（setsid 脱离会话，防止终端关闭时被杀） ------------------------
log "启动 xray..."
setsid nohup "$XRAY_BIN" run -c "$CONFIG" >> "$XRAY_LOG" 2>&1 < /dev/null &
logf "已启动 xray"

if [ "$NOWAIT" -eq 1 ]; then
    log "已后台启动（未等待就绪），请稍后用 source ~/proxy-on.sh 开启代理。"
    exit 0
fi

# --- 等待代理端口可用 --------------------------------------------------------
for _ in $(seq 1 40); do
    if curl -s -o /dev/null --max-time 2 -x "http://$HTTP_ADDR" http://cp.cloudflare.com/ 2>/dev/null; then
        log "代理已就绪 -> HTTP $HTTP_ADDR / SOCKS5 127.0.0.1:10808"
        logf "代理就绪"
        exit 0
    fi
    if ! pgrep -f "$XRAY_BIN run" >/dev/null 2>&1; then
        log "错误：xray 进程已退出，请查看 $XRAY_LOG"
        logf "错误：xray 进程异常退出"
        exit 1
    fi
    sleep 0.3
done

log "警告：代理端口未在预期时间内就绪，请查看 $XRAY_LOG"
logf "警告：端口未就绪"
exit 1
