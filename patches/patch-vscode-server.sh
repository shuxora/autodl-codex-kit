#!/usr/bin/env bash
# ============================================================================
# 给 VS Code 服务端启动脚本注入代理环境变量（幂等）
#
# 背景：
#   Remote-SSH 启动的 VS Code 服务端默认【没有任何代理环境变量】，于是
#     - 扩展宿主(openai.chatgpt) 自己的 fetch 直连 chatgpt.com -> TypeError: fetch failed
#     - 扩展 spawn 的 codex 子进程同样无代理 -> failed to send request / status 432
#   而终端里的 codex 正常，因为 /usr/local/bin/codex 包装层会自己注入。
#
# 原理：
#   VS Code 服务端由 <server>/bin/code-server 这个 sh 启动脚本拉起（进程树：
#   sh code-server -> node server-main.js -> extensionHost -> codex）。
#   在该脚本最终 exec node 之前 source 一个环境文件，整条链就都带代理了。
#
# ⚠ VS Code 升级/重装会生成新的 server 目录，补丁随之失效 —— 重跑本脚本即可。
#    检测是否失效：bash doctor.sh
#
# 用法：bash patches/patch-vscode-server.sh
# ============================================================================
set -uo pipefail

ENV_FILE=/root/vscode-proxy-env.sh
MARK='vscode-proxy-env.sh'

[ -f "$ENV_FILE" ] || { echo "✘ 缺少 $ENV_FILE（先跑 install.sh）"; exit 1; }

mapfile -t targets < <(ls -1 /root/.vscode-server/cli/servers/*/server/bin/code-server 2>/dev/null)

if [ "${#targets[@]}" -eq 0 ]; then
    cat <<'EOF'
! 未找到 VS Code 服务端启动脚本（可能还没连接过 Remote-SSH，或用了其它安装方式）。
  处理办法：
    1) 先用 VS Code 连一次这个容器，让服务端落地到 ~/.vscode-server/；
    2) 然后重跑本脚本；
    3) 若路径不同，可手工在服务端的 sh 启动脚本里、node 启动行之前加上：
         [ -f /root/vscode-proxy-env.sh ] && . /root/vscode-proxy-env.sh
EOF
    exit 0
fi

patched=0
for f in "${targets[@]}"; do
    if grep -q "$MARK" "$f" 2>/dev/null; then
        echo "  [跳过] 已打过补丁：$f"
        continue
    fi
    cp -a "$f" "$f.kit-bak"
    if python3 - "$f" <<'PY'
import io, sys
p = sys.argv[1]
lines = io.open(p, encoding="utf-8").read().splitlines(keepends=True)
idx = None
for i, l in enumerate(lines):
    if '$ROOT/node' in l:          # 实际的 node 启动行
        idx = i
if idx is None:
    sys.exit(2)
block = ("\n# [autodl-codex-kit] 注入本地 Xray 代理环境变量，否则扩展宿主及其子进程(codex)\n"
         "# 无法访问 chatgpt.com / api.openai.com（表现为 TypeError: fetch failed）\n"
         "[ -f /root/vscode-proxy-env.sh ] && . /root/vscode-proxy-env.sh\n\n")
lines.insert(idx, block)
io.open(p, "w", encoding="utf-8").write("".join(lines))
PY
    then
        echo "  [打补丁] $f"
        patched=$((patched + 1))
    else
        echo "  [失败] $f 结构不符（未找到 node 启动行），已还原"
        mv -f "$f.kit-bak" "$f"
    fi
done

echo "  完成：新增 $patched 处补丁（原文件备份为 *.kit-bak）"
[ "$patched" -gt 0 ] && echo "  ⚠ 需要重启 VS Code 服务端才生效：bash /root/restart-vscode-server.sh"
exit 0
