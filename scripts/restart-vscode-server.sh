#!/bin/bash
# ============================================================================
# 重启 VS Code 服务端 —— 让 /root/vscode-proxy-env.sh 注入的代理环境变量生效
#
# 必须在终端里执行（不能在 VS Code 的终端里执行，会因为服务端被杀而中断）。
# 用法：从 MobaXterm / 另一个 SSH 窗口执行：
#     bash /root/restart-vscode-server.sh
# 或者：在 VS Code 里按 Ctrl+Shift+P -> "Remote-SSH: Kill VS Code Server on Host"
#       然后重新连接（Reload Window 不够，必须重启服务端进程）。
# ============================================================================
set -u

echo "[1/3] 拉取 Xray 代理..."
[ -x /root/startup.sh ] && /root/startup.sh -q || true

echo "[2/3] 杀掉 VS Code 服务端进程（含扩展宿主、扩展 spawn 的旧 codex）..."
# 1) 服务端主链：launcher(sh) + server-main.js + ptyHost/extensionHost 等
pkill -f '/root/.vscode-server/' 2>/dev/null
# 2) 扩展/CLI 遗留的 codex 子进程（它们没有代理 env，且占用 unix socket 会干扰新实例）
pkill -f 'node /usr/bin/codex' 2>/dev/null
pkill -f '/usr/lib/node_modules/@openai/codex/' 2>/dev/null
sleep 2

echo "[3/3] 剩余相关进程："
pgrep -af 'vscode-server' | head -5 || echo "(已全部退出，客户端会自动重连)"

cat <<'EOF'

完成。请在 VS Code 客户端重新连接（Remote-SSH 一般会自动重连）。
验证方法 —— 重连后在 VS Code 终端里执行：
    ps -eo pid,cmd | grep '[o]penai.chatgpt.*codex' | awk '{print $1}' | while read p; do
      tr '\0' '\n' < /proc/$p/environ | grep -c proxy; done
输出应为非 0 数字（说明扩展 spawn 的 codex 已带上代理）。
EOF
