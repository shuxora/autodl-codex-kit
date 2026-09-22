#!/usr/bin/env bash
# ============================================================================
# AI 环境一键部署套件（AutoDL 版）
#
#   目标：把「搭代理 + 装 Codex + 修 VS Code 扩展」这套折腾固化成一条命令，
#         新容器（或重置系统后）直接跑本脚本即可恢复到可用状态。
#
# 用法：
#   bash ~/autodl-tmp/autodl-codex-kit/install.sh              # 全量部署（幂等，可反复跑）
#   bash ~/autodl-tmp/autodl-codex-kit/install.sh --no-vscode  # 不碰 VS Code（纯 CLi 场景）
#   KIT_NODE=16 bash ~/autodl-tmp/autodl-codex-kit/install.sh  # 指定首选节点序号
#
# 幂等说明：已存在且正确的配置一律跳过，不做破坏性覆盖；
#           需要改动的文件都会先备份为 *.proxykit-bak。
# ============================================================================
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${XRAY_DATA_DIR:-/root/autodl-tmp}"
XRAY_DIR="${XRAY_DIR:-$DATA_DIR/xray-core}"
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
HTTP_ADDR=127.0.0.1:10809
SOCKS_ADDR=127.0.0.1:10808
PROXY_URL="http://$HTTP_ADDR"

DO_VSCODE=1
DO_NPM=1
for a in "$@"; do
    case "$a" in
        --no-vscode) DO_VSCODE=0 ;;
        --no-npm)    DO_NPM=0 ;;
        -h|--help)   sed -n '2,16p' "$0"; exit 0 ;;
    esac
done

# --- 输出工具 -----------------------------------------------------------------
C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'
STEP=0
RESULT_OK=(); RESULT_WARN=(); RESULT_FAIL=()
step() { STEP=$((STEP+1)); printf '\n%s[%d] %s%s\n' "$C_B" "$STEP" "$*" "$C_0"; }
ok()   { printf '    %s✔%s %s\n' "$C_G" "$C_0" "$*"; RESULT_OK+=("$*"); }
warn() { printf '    %s!%s %s\n' "$C_Y" "$C_0" "$*"; RESULT_WARN+=("$*"); }
fail() { printf '    %s✘%s %s\n' "$C_R" "$C_0" "$*"; RESULT_FAIL+=("$*"); }
info() { printf '      %s\n' "$*"; }

proxy_port_alive() { python3 -c 'import socket,sys
try: socket.create_connection(("127.0.0.1",10809),1).close()
except Exception: sys.exit(1)' 2>/dev/null; }

# --- 联网下载（三级回退，顺序按实测速度排：本地代理 > 直连 > 学术加速） -------
# 注意：bin/xray 与 assets/*.dat 不入 git 仓库（65MB），从仓库 clone 后靠这里自动获取。
# 实测（AutoDL/2026-09）：直连 GitHub 8s 超时；学术加速 302 但吞吐慢；
# 本地 Xray 代理最快（0.5s 握手、数 MB/s），所以放第一位。
fetch_url() {
    local url="$1" out="$2"
    _try() { curl -fsSL --connect-timeout 8 --max-time "${FETCH_MAXTIME:-300}" -o "$out" "$@" "$url"; }

    if proxy_port_alive; then
        if _try -x "$PROXY_URL"; then info "（经本地 Xray 代理，最快路径）"; return 0; fi
    fi
    if _try --noproxy '*'; then info "（直连成功）"; return 0; fi
    if [ -f /etc/network_turbo ]; then
        info "本地代理/直连均不可用，改用校园学术加速（吞吐较低，请耐心等待）..."
        if ( FETCH_MAXTIME=900; . /etc/network_turbo >/dev/null 2>&1; _try ); then
            info "（经学术加速）"; return 0
        fi
    fi
    return 1
}

# 下载官方发行包（含 xray + geoip.dat + geosite.dat），安装 xray 二进制并顺带铺好 geo 数据
fetch_xray_release() {
    local tmp; tmp=$(mktemp -d)
    local url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
    echo "      正在下载 Xray 发行包（约 20MB）..."
    if ! fetch_url "$url" "$tmp/xray.zip"; then
        rm -rf "$tmp"
        return 1
    fi
    if ! python3 - "$tmp/xray.zip" "$tmp" <<'PY'
import sys, zipfile
try:
    zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
except Exception as e:
    print(f"解压失败：{e}"); sys.exit(1)
PY
    then rm -rf "$tmp"; return 1; fi
    install -m 0755 "$tmp/xray" "$XRAY_BIN" || { rm -rf "$tmp"; return 1; }
    for f in geoip.dat geosite.dat; do
        [ -f "$tmp/$f" ] && cp -f "$tmp/$f" "$XRAY_DIR/$f"
    done
    rm -rf "$tmp"
    return 0
}

[ "$(id -u)" -eq 0 ] || { fail "请用 root 运行（当前 uid=$(id -u)）"; exit 1; }

printf '%s' "$C_B"
cat <<'BANNER'
============================================================
   AI 环境一键部署套件 (autodl-codex-kit)
   代理 -> Codex -> VS Code 扩展，一步到位
============================================================
BANNER
printf '%s' "$C_0"

# ============================================================================
step "环境前置检查"
# ============================================================================
missing=0
for c in curl python3 bash; do
    if command -v "$c" >/dev/null 2>&1; then ok "$c 已就绪"; else fail "缺少 $c"; missing=1; fi
done
if [ -d "$DATA_DIR" ]; then ok "数据盘目录存在：$DATA_DIR"
else warn "$DATA_DIR 不存在（非 AutoDL 布局？将仍按此路径部署）"; fi
[ "$missing" -eq 1 ] && { fail "缺少必要命令，终止"; exit 1; }

# ============================================================================
step "部署 Xray 可执行文件"
# ============================================================================
if [ -x "$XRAY_BIN" ]; then
    ok "$XRAY_BIN 已存在（$("$XRAY_BIN" version 2>/dev/null | head -1 || echo '版本未知')）"
else
    mkdir -p /usr/local/bin
    if [ -x "$KIT_DIR/bin/xray" ]; then
        install -m 0755 "$KIT_DIR/bin/xray" "$XRAY_BIN" && ok "已从套件复制 xray 到 $XRAY_BIN"
    elif [ -x "$XRAY_DIR/xray" ]; then
        install -m 0755 "$XRAY_DIR/xray" "$XRAY_BIN" && ok "已从 $XRAY_DIR 复制 xray"
    elif fetch_xray_release; then
        ok "已从 GitHub 下载安装 xray（同时获得 geo 数据）"
    else
        fail "xray 获取失败（套件内无二进制且下载不通报）"
        info "手动办法：先 source /etc/network_turbo 开学术加速，再重跑本脚本；"
        info "或手动下载 https://github.com/XTLS/Xray-core/releases 解压到 $KIT_DIR/bin/xray"
    fi
fi

# ============================================================================
step "准备运行目录与 geo 数据"
# ============================================================================
mkdir -p "$XRAY_DIR"
ok "运行目录：$XRAY_DIR"
for f in geoip.dat geosite.dat; do
    if [ -f "$XRAY_DIR/$f" ]; then ok "$f 已存在"
    elif [ -f "$KIT_DIR/assets/$f" ]; then cp -a "$KIT_DIR/assets/$f" "$XRAY_DIR/$f" && ok "已复制 $f（geoip:private 路由需要）"
    elif [ -x "$XRAY_BIN" ] && fetch_xray_release; then
        if [ -f "$XRAY_DIR/$f" ]; then ok "$f 已随发行包补齐"
        else warn "下载成功但发行包内无 $f"; fi
    else
        warn "缺少 $f，私有 IP 直连规则可能失效（可从发行包 Xray-linux-64.zip 中取）"
    fi
done

# ============================================================================
step "部署脚本到标准位置"
# ============================================================================
install_one() {   # install_one <源> <目标> [权限]
    local src="$1" dst="$2" mode="${3:-0755}"
    if [ -f "$src" ]; then
        install -m "$mode" "$src" "$dst" && ok "→ $dst"
    else
        warn "套件内缺少 $src，跳过"
    fi
}
install_one "$KIT_DIR/scripts/startup.sh"              /root/startup.sh
install_one "$KIT_DIR/scripts/proxy-on.sh"             /root/proxy-on.sh
install_one "$KIT_DIR/scripts/proxy-off.sh"            /root/proxy-off.sh
install_one "$KIT_DIR/scripts/vscode-proxy-env.sh"     /root/vscode-proxy-env.sh
install_one "$KIT_DIR/scripts/restart-vscode-server.sh" /root/restart-vscode-server.sh
install_one "$KIT_DIR/scripts/codex-wrapper.sh"        /usr/local/bin/codex
install_one "$KIT_DIR/tools/xray-node.py"              /root/xray-node.py
install_one "$KIT_DIR/tools/xray-bench.py"             /root/xray-bench.py

# 订阅链接文件（若存在）一并部署到 /root/，供安装后的 xray-node.py 自动读取
if [ -f "$KIT_DIR/sub-url.txt" ]; then
    install -m 0600 "$KIT_DIR/sub-url.txt" /root/sub-url.txt && ok "→ /root/sub-url.txt（订阅链接，权限 600）"
fi

# ============================================================================
step "配置节点（config.json）"
# ============================================================================
if [ -f "$XRAY_DIR/config.json" ]; then
    ok "config.json 已存在，保持不动（换节点请跑 python3 /root/xray-node.py <序号>）"
else
    # 订阅链接：优先环境变量 SUB_URL，其次套件目录下的 sub-url.txt（该文件不入库）
    if [ -z "${SUB_URL:-}" ] && [ -f "$KIT_DIR/sub-url.txt" ]; then
        SUB_URL=$(head -1 "$KIT_DIR/sub-url.txt" | tr -d '\r')
    fi
    export SUB_URL
    if [ -z "${SUB_URL:-}" ]; then
        fail "未设置订阅链接（SUB_URL），无法自动生成 config.json"
        info "两种方式任选其一："
        info "  ① export SUB_URL=\"你的订阅链接\"   然后重跑本脚本"
        info "  ② echo \"你的订阅链接\" > $KIT_DIR/sub-url.txt   （该文件已被 .gitignore 忽略）"
    fi
    pick="${KIT_NODE:-}"
    if [ -z "$pick" ]; then
        echo "      正在拉取订阅并挑选节点（默认优先『日本』，否则用第 1 个）..."
        out=$(python3 /root/xray-node.py -u 2>&1) || true
        echo "$out" | tail -3 | sed 's/^/      /'
        pick=$(python3 - <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("xn", "/root/xray-node.py")
xn = importlib.util.module_from_spec(spec); spec.loader.exec_module(xn)
try:
    nodes = xn.load_nodes(update=False)
except Exception:
    sys.exit(0)
if not nodes:
    sys.exit(0)
for i, n in enumerate(nodes, 1):
    if "日本" in (n["name"] or ""):
        print(i); break
else:
    print(1)
PY
)
    fi
    if [ -n "$pick" ]; then
        out=$(python3 /root/xray-node.py "$pick" 2>&1); rc=$?
        echo "$out" | sed 's/^/      /'
        if [ "$rc" -eq 0 ]; then ok "已按序号 $pick 生成 config.json"
        else fail "节点 $pick 配置失败，请手动跑：python3 /root/xray-node.py"; fi
    else
        fail "无法自动选节点，请手动跑：python3 /root/xray-node.py -u  →  python3 /root/xray-node.py <序号>"
    fi
fi

# ============================================================================
step "启动代理并验证连通性"
# ============================================================================
bash /root/startup.sh 2>&1 | sed 's/^/      /' || true
if proxy_port_alive; then
    ok "本地代理端口就绪：HTTP $HTTP_ADDR / SOCKS5 $SOCKS_ADDR"
    trace=$(curl -sS -m 20 -x "$PROXY_URL" https://chatgpt.com/cdn-cgi/trace 2>/dev/null | grep -E '^(ip|loc)=' | tr '\n' ' ')
    if [ -n "$trace" ]; then ok "出口正常：$trace"
    else warn "代理端口通，但访问 chatgpt.com 失败（换节点试试：python3 /root/xray-node.py）"; fi
else
    fail "代理端口不通，请查看 $XRAY_DIR/xray.log"
fi

# ============================================================================
step "配置开机自启（/etc/autodl.sh）"
# ============================================================================
HOOK=/etc/autodl.sh
if [ -f "$HOOK" ] && grep -q 'startup.sh' "$HOOK"; then
    ok "$HOOK 已包含启动逻辑"
else
    [ -f "$HOOK" ] && cp -a "$HOOK" "$HOOK.kit-bak"
    install -m 0755 "$KIT_DIR/conf/autodl-hook.sh" "$HOOK" && ok "已写入 $HOOK（调用 /root/startup.sh -u）"
fi
info "调用链：supervisord -> /init/bin/customer.cmd.sh -> /etc/autodl.sh -> /root/startup.sh"

# ============================================================================
step "配置 .bashrc 代理逻辑"
# ============================================================================
BRC=/root/.bashrc
if grep -q 'autodl-codex-kit' "$BRC" 2>/dev/null; then
    ok ".bashrc 已含 autodl-codex-kit 段落"
elif grep -q '/root/startup.sh' "$BRC" 2>/dev/null; then
    ok ".bashrc 已有等价的代理逻辑（未加标记，跳过以免重复追加）"
else
    cp -a "$BRC" "$BRC.kit-bak"
    cat "$KIT_DIR/conf/bashrc-proxy-block.sh" >> "$BRC" && ok "已追加代理段落到 $BRC"
fi
info "新终端自动开代理：touch $XRAY_DIR/auto-proxy  ／ 取消：rm $XRAY_DIR/auto-proxy"

# ============================================================================
step "Codex CLI"
# ============================================================================
if [ -x /usr/bin/codex ] || command -v codex >/dev/null 2>&1; then
    cver=$(/usr/bin/codex --version 2>/dev/null | head -1)
    ok "codex 已安装：$(command -v codex)（${cver:-版本未知}）"
else
    if [ "$DO_NPM" -eq 1 ] && command -v npm >/dev/null 2>&1; then
        info "正在安装 @openai/codex（走 npmmirror 加速）..."
        npm config set registry https://registry.npmmirror.com >/dev/null 2>&1
        if npm install -g @openai/codex >/tmp/kit-npm.log 2>&1; then ok "codex 安装完成"
        else fail "npm 安装失败，详见 /tmp/kit-npm.log"; fi
    else
        warn "未安装 codex（npm 不可用或已用 --no-npm），请手动：npm i -g @openai/codex"
    fi
fi

# ============================================================================
step "Codex 配置（config.toml）"
# ============================================================================
CX=/root/.codex
mkdir -p "$CX"
if [ -f "$CX/config.toml" ]; then
    ok "$CX/config.toml 已存在，保持不动"
    grep -q 'sandbox_mode' "$CX/config.toml" || warn "未设置 sandbox_mode —— AutoDL 禁用 unshare，建议 sandbox_mode = \"danger-full-access\""
    # 只匹配真正的表头/键，忽略注释（注释里出现 codex_apps 是正常的说明文字）
    if grep -vE '^[[:space:]]*#' "$CX/config.toml" | grep -qE '^[[:space:]]*\[.*codex_apps.*\]|mcp_servers\.codex_apps[[:space:]]*='; then
        fail "config.toml 含 [mcp_servers.codex_apps]（会导致整份配置解析失败），请删掉该段"
    fi
else
    install -m 0644 "$KIT_DIR/conf/codex-config.toml.template" "$CX/config.toml" && ok "已写入模板 $CX/config.toml"
fi
if [ -f "$CX/auth.json" ]; then
    am=$(python3 -c "import json;print(json.load(open('$CX/auth.json')).get('auth_mode','?'))" 2>/dev/null)
    ok "已存在登录凭据（auth_mode=$am）"
else
    warn "尚未登录 Codex：终端执行 codex login（ChatGPT 登录需浏览器，容器内建议在本地登录后拷贝 auth.json）"
fi

# ============================================================================
if [ "$DO_VSCODE" -eq 1 ]; then
    step "VS Code 服务端代理注入"
    # 1) launcher 补丁
    bash "$KIT_DIR/patches/patch-vscode-server.sh" 2>&1 | sed 's/^/      /'
    # 2) Machine settings（合并，不覆盖）
    python3 - <<'PY' 2>&1 | sed 's/^/      /'
import json, os, re, shutil
p = "/root/.vscode-server/data/Machine/settings.json"
want = {
    "http.proxy": "http://127.0.0.1:10809",
    "http.proxySupport": "on",
    "http.noProxy": ["localhost", "127.0.0.1"],
}
header = ("// 由 autodl-codex-kit 维护：容器无法直连 OpenAI，统一走本地 Xray 代理。\n"
          "// 手工修改后如需重新生成，请重跑 install.sh。\n")
cur = {}
if os.path.exists(p):
    txt = open(p, encoding="utf-8").read()
    stripped = re.sub(r"^\s*//.*$", "", txt, flags=re.M)
    stripped = re.sub(r"/\*.*?\*/", "", stripped, flags=re.S)
    try:
        cur = json.loads(stripped) if stripped.strip() else {}
    except Exception:
        shutil.copy2(p, p + ".kit-bak")
        print("原 settings.json 无法解析，已备份为 .kit-bak，改为重建")
        cur = {}
else:
    os.makedirs(os.path.dirname(p), exist_ok=True)
need = {k: v for k, v in want.items() if cur.get(k) != v}
if not need and os.path.exists(p) and txt.startswith("// 由 autodl-codex-kit"):
    print("Machine settings 已是目标状态 ✔")
else:
    if os.path.exists(p) and need:
        shutil.copy2(p, p + ".kit-bak")
    cur.update(want)
    with open(p, "w", encoding="utf-8") as f:
        f.write(header + json.dumps(cur, indent=2, ensure_ascii=False) + "\n")
    print(f"已写入 {p}（新增/修正 {len(need)} 项：{', '.join(need) if need else '仅格式化'}）")
PY
    ok "VS Code 侧配置完成（launcher 补丁 + http.proxy）"
    info "⚠ 必须重启 VS Code 服务端才生效：bash /root/restart-vscode-server.sh"
else
    warn "已跳过 VS Code 部分（--no-vscode）"
fi

# ============================================================================
printf '\n%s================ 部署结果 ================%s\n' "$C_B" "$C_0"
printf '  %s成功 %d 项%s    %s警告 %d 项%s    %s失败 %d 项%s\n' \
    "$C_G" "${#RESULT_OK[@]}" "$C_0" "$C_Y" "${#RESULT_WARN[@]}" "$C_0" "$C_R" "${#RESULT_FAIL[@]}" "$C_0"
if [ "${#RESULT_WARN[@]}" -gt 0 ]; then echo; echo "  ⚠ 警告："; printf '    - %s\n' "${RESULT_WARN[@]}"; fi
if [ "${#RESULT_FAIL[@]}" -gt 0 ]; then echo; echo "  ✘ 失败："; printf '    - %s\n' "${RESULT_FAIL[@]}"; fi

cat <<EOF

  下一步：
    1) 自检          bash $KIT_DIR/doctor.sh
    2) 开代理        source /root/proxy-on.sh
    3) 换节点        python3 /root/xray-node.py            （列出）
                     python3 /root/xray-node.py 16         （切到 16 号）
                     python3 /root/xray-bench.py 8 16 25   （测速对比）
    4) 验证 codex    cd /root && codex exec "只回复两字：正常" --skip-git-repo-check
    5) VS Code 生效  bash /root/restart-vscode-server.sh   （然后等待客户端自动重连）

EOF
[ "${#RESULT_FAIL[@]}" -eq 0 ] || exit 1
