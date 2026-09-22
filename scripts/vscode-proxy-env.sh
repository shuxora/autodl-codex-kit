#!/bin/sh
# ============================================================================
# VS Code 服务端代理环境注入脚本
#
# 被 /root/.vscode-server/cli/servers/*/server/bin/code-server 在启动前 source。
#
# 为什么需要：
#   AutoDL 容器无法直连 chatgpt.com（Connection refused），必须走本地 Xray 代理。
#   Remote-SSH 启动的 VS Code 服务端默认【没有】任何代理环境变量，导致：
#     - 扩展宿主(openai.chatgpt) 的 fetch 直连失败 -> TypeError: fetch failed
#     - 扩展 spawn 的 codex 子进程直连失败 -> failed to send request
#   本脚本把代理变量注入服务端进程，扩展及其所有子进程都会继承。
#
# 注意：本文件被 /bin/sh (dash) source，所以不能使用 bash 专有的 /dev/tcp。
# ============================================================================

PROXY_HTTP="http://127.0.0.1:10809"
PROXY_SOCKS="socks5://127.0.0.1:10808"

proxy_alive() {
    python3 -c 'import socket,sys
try:
    socket.create_connection(("127.0.0.1",10809),1).close()
except Exception:
    sys.exit(1)' 2>/dev/null
}

# 代理没起来就先拉起来（startup.sh 幂等 + flock 防并发）
if ! proxy_alive; then
    [ -x /root/startup.sh ] && /root/startup.sh -q >/dev/null 2>&1
    i=0
    while [ "$i" -lt 20 ] && ! proxy_alive; do
        i=$((i + 1))
        sleep 0.5
    done
fi

export http_proxy="$PROXY_HTTP"
export https_proxy="$PROXY_HTTP"
export HTTP_PROXY="$PROXY_HTTP"
export HTTPS_PROXY="$PROXY_HTTP"
export all_proxy="$PROXY_SOCKS"
export ALL_PROXY="$PROXY_SOCKS"
export no_proxy="localhost,127.0.0.1,::1"
export NO_PROXY="$no_proxy"
