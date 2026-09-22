#!/bin/bash
# ============================================================================
# Codex CLI 包装层 —— 自动确保本地代理可用后再调用真正的 codex
#
# 为什么需要：
#   Codex 必须访问 chatgpt.com / api.openai.com，本容器无法直连，必须走 Xray
#   本地代理。若 shell 里没有 http_proxy 变量，codex 会「静默卡死」而不报错。
#   本包装层保证无论从哪个终端、脚本还是任务调用，代理都自动生效。
#
# 真正的可执行文件：/usr/bin/codex
# 确认本包装生效：which codex    （应输出 /usr/local/bin/codex）
# 临时绕过本包装：/usr/bin/codex ...
# ============================================================================

PROXY_HTTP=http://127.0.0.1:10809
PROXY_SOCKS=socks5://127.0.0.1:10808

proxy_port_alive() {
    (exec 3<>/dev/tcp/127.0.0.1/10809) 2>/dev/null
}

# 已经手动设置过代理（例如 source ~/proxy-on.sh）则尊重用户设置
if [ -z "${http_proxy:-}" ] && [ -z "${https_proxy:-}" ]; then
    # 端口不通就拉起 xray（startup.sh 幂等，已在运行会立刻返回）
    if ! proxy_port_alive; then
        [ -x /root/startup.sh ] && /root/startup.sh -q >/dev/null 2>&1
    fi

    export http_proxy="$PROXY_HTTP"
    export https_proxy="$PROXY_HTTP"
    export all_proxy="$PROXY_SOCKS"
    export no_proxy="localhost,127.0.0.1"

    # 兜底提示：代理仍不通时明确报错，避免用户面对无输出的假死
    if ! proxy_port_alive; then
        echo "[codex] 警告：本地代理 127.0.0.1:10809 未就绪，codex 可能会卡住。" >&2
        echo "[codex] 请手动执行排查：bash /root/startup.sh" >&2
    fi
fi

exec /usr/bin/codex "$@"
