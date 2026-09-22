#!/usr/bin/env bash
# ============================================================================
# 把 autodl-codex-kit 推送到你自己的仓库（公开或私有，首次配置 + 推送，一条命令搞定）
#
# 用法：
#     bash setup-github.sh git@github.com:你的用户名/autodl-codex-kit.git
#     bash setup-github.sh https://github.com/你的用户名/autodl-codex-kit.git
#
# 前置：
#   1) 已在 GitHub 上建好一个【Private】空仓库（不要勾选 README/gitignore 初始化）
#   2) 若用 HTTPS：准备 Personal Access Token（勾 repo 权限），
#      推送时提示 Password 就粘贴 token（注意：不要把它发给任何人/贴进聊天窗口）
#   3) 若用 SSH：先把公钥加到 GitHub（ssh-keygen -t ed25519 -C "你的邮箱"）
#
# 本脚本做的事：确保代理可用 → 设置 remote → 推送 → 打印新容器使用步骤
# ============================================================================
set -uo pipefail

REMOTE="${1:-}"
if [ -z "$REMOTE" ]; then
    sed -n '3,18p' "$0"
    exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_B=$'\e[36m'; C_0=$'\e[0m'

echo "${C_B}[1/4] 确保访问 github.com 的网络通道${C_0}"
if [ -z "${https_proxy:-}" ] && [ -z "${http_proxy:-}" ]; then
    if python3 -c 'import socket,sys
try: socket.create_connection(("127.0.0.1",10809),1).close()
except Exception: sys.exit(1)' 2>/dev/null; then
        export http_proxy=http://127.0.0.1:10809
        export https_proxy=http://127.0.0.1:10809
        export all_proxy=socks5://127.0.0.1:10808
        export no_proxy=localhost,127.0.0.1
        echo "  ${C_G}✔${C_0} 已自动使用本地 Xray 代理"
    else
        [ -x /root/startup.sh ] && bash /root/startup.sh -q >/dev/null 2>&1
        export http_proxy=http://127.0.0.1:10809
        export https_proxy=http://127.0.0.1:10809
        echo "  ${C_Y}!${C_0} 代理没起来，已尝试拉起；若推送失败先跑：source ~/proxy-on.sh"
    fi
else
    echo "  ${C_G}✔${C_0} 当前 shell 已有代理变量"
fi

echo "${C_B}[2/4] 连通性检查${C_0}"
if curl -sS -m 15 -o /dev/null -w '' https://github.com/ 2>/dev/null; then
    echo "  ${C_G}✔${C_0} github.com 可达"
else
    echo "  ${C_R}✘${C_0} github.com 不可达 —— 先解决网络：bash ../autodl-codex-kit/doctor.sh ①"
    exit 1
fi

echo "${C_B}[3/4] 配置远端${C_0}"
if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$REMOTE"
    echo "  ${C_G}✔${C_0} 已更新 origin = $REMOTE"
else
    git remote add origin "$REMOTE"
    echo "  ${C_G}✔${C_0} 已添加 origin = $REMOTE"
fi

echo "${C_B}[4/4] 推送${C_0}"
if git push -u origin main; then
    echo
    echo "${C_G}推送成功 🎉${C_0}"
    cat <<EOF

  以后在本机更新后，一条命令同步：
      cd ~/autodl-tmp/autodl-codex-kit && git add -A && git commit -m "update" && git push

  新容器里恢复环境：
      git clone $REMOTE ~/autodl-tmp/autodl-codex-kit
      bash ~/autodl-tmp/autodl-codex-kit/install.sh

  ⚠ 新容器里 git clone / push 同样需要代理，先 source /root/proxy-on.sh
  ⚠ 本仓库代码不含任何凭据；你的订阅链接请放在 sub-url.txt（已 gitignore）或
    环境变量 SUB_URL 里，不要提交进仓库
EOF
else
    echo
    echo "${C_R}推送失败${C_0} 常见原因："
    echo "  · HTTPS：用户名填 GitHub 用户名，密码处粘贴 Personal Access Token（不是登录密码）"
    echo "  · SSH：公钥没加到 GitHub，或没有 ~/.ssh/id_ed25519"
    echo "  · 远端仓库已有提交（建库时勾了 README/gitignore）→ git pull --rebase origin main 后再推"
    echo "  · 网络：先 source ~/proxy-on.sh"
    exit 1
fi
