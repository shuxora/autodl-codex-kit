#!/usr/bin/env bash
# ============================================================================
# autodl-codex-kit 自检体检 —— 分层排查「Codex / ChatGPT 扩展用不了」类问题
#
# 用法：
#   bash doctor.sh            # 快速体检（默认，约 3 秒）
#   bash doctor.sh --exec     # 附带 codex 端到端实跑（约 30 秒，最权威）
#
# 退出码：0 全部正常 / 1 有致命问题 / 2 仅有警告
# ============================================================================
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XRAY_DIR=/root/autodl-tmp/xray-core
XRAY_BIN=/usr/local/bin/xray
HTTP_ADDR=127.0.0.1:10809
PROXY_URL="http://$HTTP_ADDR"
RUN_EXEC=0
[ "${1:-}" = "--exec" ] && RUN_EXEC=1

C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_D=$'\e[2m'; C_0=$'\e[0m'
FAILS=0; WARNS=0
pass() { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$1"; [ -n "${2:-}" ] && printf '      %s%s%s\n' "$C_D" "$2" "$C_0"; return 0; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$1"; [ -n "${2:-}" ] && printf '      %s%s%s\n' "$C_D" "$2" "$C_0"; WARNS=$((WARNS+1)); return 0; }
bad()  { printf '  %s✘%s %s\n' "$C_R" "$C_0" "$1"; [ -n "${2:-}" ] && printf '      %s%s%s\n' "$C_D" "$2" "$C_0"; FAILS=$((FAILS+1)); return 0; }
section() { printf '\n%s── %s ──%s\n' "$C_B" "$1" "$C_0"; }

printf '%sautodl-codex-kit doctor%s  %s\n' "$C_B" "$C_0" "$(date '+%F %T')"

# ============================================================================
section "① 代理链路"
# ============================================================================
if [ -x "$XRAY_BIN" ]; then pass "xray 可执行文件存在" "$XRAY_BIN"
else bad "找不到 $XRAY_BIN" "跑 bash $KIT_DIR/install.sh"; fi

if [ -f "$XRAY_DIR/config.json" ]; then pass "节点配置存在" "$XRAY_DIR/config.json"
else bad "缺少 config.json" "需先设置订阅链接：export SUB_URL=\"你的订阅链接\" 或写入 sub-url.txt，再跑 install.sh"; fi

if [ -n "${SUB_URL:-}" ] || [ -f "$KIT_DIR/sub-url.txt" ] || [ -f /root/sub-url.txt ]; then
    pass "订阅链接已配置" "支持换节点与更新订阅"
else
    warn "未配置订阅链接（SUB_URL / sub-url.txt）" "换节点、更新订阅会失败；仅当已有 config.json 时不影响使用"
fi

if pgrep -f "$XRAY_BIN run" >/dev/null 2>&1; then
    pass "xray 进程运行中" "PID $(pgrep -f "$XRAY_BIN run" | head -1)"
else
    bad "xray 未运行" "bash /root/startup.sh   或   source /root/proxy-on.sh"
fi

if python3 -c 'import socket,sys
try: socket.create_connection(("127.0.0.1",10809),1).close()
except Exception: sys.exit(1)' 2>/dev/null; then
    pass "本地代理端口就绪" "HTTP $HTTP_ADDR / SOCKS5 127.0.0.1:10808"
else
    bad "代理端口 $HTTP_ADDR 不通" "查日志：tail -30 $XRAY_DIR/xray.log"
fi

trace=$(curl -sS -m 20 -x "$PROXY_URL" https://chatgpt.com/cdn-cgi/trace 2>/dev/null | grep -E '^(ip|loc)=' | tr '\n' ' ')
if [ -n "$trace" ]; then pass "代理出口可用" "$trace"
else
    if python3 -c 'import socket,sys
try: socket.create_connection(("127.0.0.1",10809),1).close()
except Exception: sys.exit(1)' 2>/dev/null; then
        warn "端口通但 chatgpt.com 访问失败" "换个节点：python3 /root/xray-node.py（香港节点不支持 OpenAI）"
    fi
fi

code=$(curl -sS -m 20 -x "$PROXY_URL" -o /dev/null -w '%{http_code}' https://api.openai.com/v1/models 2>/dev/null)
case "$code" in
    401) pass "api.openai.com 可达（401=正常，仅缺凭据）" ;;
    000) warn "api.openai.com 经代理不可达" "换节点：python3 /root/xray-bench.py 8 16 25" ;;
    *)   pass "api.openai.com 返回 $code" ;;
esac

if curl -sS -m 8 --noproxy '*' -o /dev/null https://chatgpt.com/ 2>/dev/null; then
    warn "容器竟能直连 chatgpt.com" "若为真则无需代理，但 AutoDL 一般不允许"
else
    pass "直连确实不通（印证必须走代理）"
fi

# ============================================================================
section "② Codex CLI"
# ============================================================================
if [ -x /usr/bin/codex ] || command -v codex >/dev/null 2>&1; then
    pass "codex 已安装" "$(/usr/bin/codex --version 2>/dev/null | head -1)"
else
    bad "codex 未安装" "npm i -g @openai/codex"
fi

wrapper=$(command -v codex 2>/dev/null || echo "")
if [ "$wrapper" = "/usr/local/bin/codex" ]; then
    pass "代理包装层生效（PATH 优先）" "which codex -> $wrapper"
else
    warn "codex 未走包装层（which codex = ${wrapper:-无}）" "install.sh 会把包装层装到 /usr/local/bin/codex"
fi

if [ -f /root/.codex/auth.json ]; then
    am=$(python3 -c "import json;d=json.load(open('/root/.codex/auth.json'));print(d.get('auth_mode','?'))" 2>/dev/null)
    st=$(/usr/bin/codex login status 2>&1 | head -1)
    pass "登录凭据存在" "auth_mode=$am | $st"
    [ "$am" = "chatgpt" ] && printf '      %s注：refresh_token 续期需要联网，断网会导致凭据失效%s\n' "$C_D" "$C_0"
else
    bad "未登录 Codex" "codex login（需浏览器，容器内可本地登录后拷 auth.json）"
fi

if [ -f /root/.codex/config.toml ]; then
    # 只匹配真正的表头/键，忽略注释行（注释里提到 codex_apps 是正常的说明文字）
    if grep -vE '^[[:space:]]*#' /root/.codex/config.toml | grep -qE '^[[:space:]]*\[.*codex_apps.*\]|mcp_servers\.codex_apps[[:space:]]*='; then
        bad "config.toml 含 [mcp_servers.codex_apps]" "会导致整份配置解析失败，删掉该段；要关连接器请用 features.apps = false"
    fi
    if grep -q 'sandbox_mode' /root/.codex/config.toml; then
        sm=$(grep -m1 'sandbox_mode' /root/.codex/config.toml | tr -d ' "')
        case "$sm" in
            *danger-full-access*) pass "沙箱已放开（AutoDL 禁用 unshare，必须如此）" "$sm" ;;
            *) warn "sandbox_mode 非 danger-full-access，命令可能全部 exit 1" "$sm" ;;
        esac
    else
        warn "未设置 sandbox_mode" "AutoDL 禁 unshare/bwrap，需 sandbox_mode = \"danger-full-access\"（且必须在所有 [table] 之前）"
    fi
else
    warn "缺少 /root/.codex/config.toml" "install.sh 会写入模板"
fi

if [ "$RUN_EXEC" -eq 1 ]; then
    printf '  %s… 正在实跑 codex（约 30 秒）%s\n' "$C_D" "$C_0"
    out=$(cd /root && timeout 90 /usr/local/bin/codex exec "只回复两字：正常" --skip-git-repo-check 2>&1)
    if echo "$out" | grep -q "正常"; then
        pass "端到端实跑成功" "$(echo "$out" | grep -c . ) 行输出，模型可用"
    else
        bad "端到端实跑失败" "$(echo "$out" | tail -3 | tr '\n' ' ')"
    fi
fi

# ============================================================================
section "③ VS Code 服务端（扩展所在环境）"
# ============================================================================
vsc_running=0
while read -r p; do
    [ -z "$p" ] && continue
    n=$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -ci proxy)
    if [ "${n:-0}" -gt 0 ]; then
        pass "服务端进程已带代理" "pid=$p proxy_vars=$n"
        vsc_running=1
    else
        bad "服务端进程【没有】代理变量" "pid=$p —— 这就是扩展报 fetch failed 的根因，跑 install.sh 后重启服务端"
        vsc_running=1
    fi
done < <(pgrep -f 'server-main.js')
[ "$vsc_running" -eq 0 ] && warn "未发现 VS Code 服务端进程" "（未连接 Remote-SSH，或用了其它安装方式）"

patched=0; total=0
for f in /root/.vscode-server/cli/servers/*/server/bin/code-server; do
    [ -f "$f" ] || continue
    total=$((total+1))
    grep -q 'vscode-proxy-env.sh' "$f" && patched=$((patched+1))
done
if [ "$total" -eq 0 ]; then
    warn "未发现服务端启动脚本" "先连一次 Remote-SSH"
elif [ "$patched" -eq "$total" ]; then
    pass "启动脚本补丁在位（$patched/$total）" "VS Code 升级后需重跑 patches/patch-vscode-server.sh"
else
    bad "启动脚本补丁缺失（$patched/$total）" "bash $KIT_DIR/patches/patch-vscode-server.sh && bash /root/restart-vscode-server.sh"
fi

MS=/root/.vscode-server/data/Machine/settings.json
if [ -f "$MS" ] && grep -q 'http.proxy' "$MS"; then
    pass "Machine settings 已配 http.proxy" "$(grep -o '"http.proxy"[^,]*' "$MS" | head -1)"
else
    warn "Machine settings 未配 http.proxy" "扩展宿主自身的 fetch 可能仍直连失败，跑 install.sh"
fi

extcodex=0
while read -r p; do
    [ -z "$p" ] && continue
    n=$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -ci proxy)
    [ "${n:-0}" -gt 0 ] && extcodex=$((extcodex+1))
done < <(pgrep -f 'openai.chatgpt.*codex')
if [ "$extcodex" -gt 0 ]; then pass "扩展 spawn 的 codex 已带代理（$extcodex 个进程）"
else warn "扩展 spawn 的 codex 未见（未打开 ChatGPT 面板，或仍无代理）" "重开面板后重跑本脚本"; fi

# ============================================================================
section "④ 持久化与自启"
# ============================================================================
if [ -f /etc/autodl.sh ] && grep -q 'startup.sh' /etc/autodl.sh; then
    pass "开机自启钩子已配" "/etc/autodl.sh -> /root/startup.sh"
else
    warn "开机自启钩子缺失" "install.sh 会写入 /etc/autodl.sh（重置系统后会丢，需重跑）"
fi

if grep -q 'autodl-codex-kit' /root/.bashrc 2>/dev/null; then
    pass ".bashrc 代理段落已配（autodl-codex-kit 标记）"
elif grep -q '/root/startup.sh' /root/.bashrc 2>/dev/null; then
    pass ".bashrc 已有等价的代理逻辑"
else
    warn ".bashrc 缺代理段落" "跑 install.sh（新终端不会自动开代理）"
fi

if [ -f "$XRAY_DIR/auto-proxy" ]; then
    pass "auto-proxy 开关：开启" "新终端自动带代理变量"
else
    pass "auto-proxy 开关：关闭" "需要自动开就：touch $XRAY_DIR/auto-proxy"
fi

if [ -d /root/.codex ] && [ "$(df --output=target /root/.codex | tail -1)" = "/" ]; then
    warn "/root/.codex 在系统盘上" "重置系统会丢失登录凭据；重要的话备份 auth.json"
fi

# ============================================================================
printf '\n%s================ 体检结论 ================%s\n' "$C_B" "$C_0"
printf '  致命 %d 项   警告 %d 项\n' "$FAILS" "$WARNS"
if [ "$FAILS" -eq 0 ] && [ "$WARNS" -eq 0 ]; then
    printf '  %s环境健康 ✔%s\n' "$C_G" "$C_0"; exit 0
elif [ "$FAILS" -eq 0 ]; then
    printf '  %s基本可用，按上面提示收尾即可%s\n' "$C_Y" "$C_0"; exit 2
else
    printf '  %s存在致命问题，先跑 install.sh，再按提示处理%s\n' "$C_R" "$C_0"; exit 1
fi
