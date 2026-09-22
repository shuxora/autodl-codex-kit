#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
机场节点切换工具（配合 Xray-core 使用）

用法：
    export SUB_URL="你的订阅链接"        # 首次使用必须先设置，或写进 ./sub-url.txt
    python3 xray-node.py                # 列出所有节点
    python3 xray-node.py 12             # 切换到 12 号节点并重启 xray
    python3 xray-node.py -u             # 更新订阅后列出节点
    python3 xray-node.py -u 12          # 更新订阅并切换到 12 号节点

可用环境变量：
    SUB_URL        订阅链接（必填；也可放一行到 <套件目录>/sub-url.txt）
    XRAY_DIR       xray 运行目录，默认 /root/autodl-tmp/xray-core
"""

import base64
import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request

# 订阅链接从环境变量读取 —— 请勿把带 token 的链接提交到公开仓库
SUB_URL = os.environ.get("SUB_URL", "").strip()
XRAY_DIR = os.environ.get("XRAY_DIR", "/root/autodl-tmp/xray-core")
CACHE_FILE = os.path.join(XRAY_DIR, "sub.txt")
CONFIG_FILE = os.path.join(XRAY_DIR, "config.json")

# 未设置环境变量时，尝试从 sub-url.txt 读取（脚本同目录 或 /root/）
if not SUB_URL:
    for _p in (
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "sub-url.txt"),
        "/root/sub-url.txt",
    ):
        if os.path.isfile(_p):
            with open(_p, encoding="utf-8") as _fh:
                SUB_URL = _fh.readline().strip()
            if SUB_URL:
                break

# 订阅里这几条只是流量/到期信息，不是真节点
INFO_PREFIXES = ("剩余流量", "距离下次重置", "套餐到期", "过期时间", "官网", "订阅")


def fetch_subscription():
    """下载并解码订阅（订阅内容是 base64 编码的 vless:// 列表）"""
    if not SUB_URL:
        raise SystemExit(
            "未设置订阅链接。请先执行：\n"
            '    export SUB_URL="你的订阅链接"\n'
            "或把链接写入一行到本脚本同目录的 sub-url.txt（该文件已被 .gitignore 忽略）。"
        )
    last_err = None
    for attempt in range(3):
        try:
            req = urllib.request.Request(SUB_URL, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read().decode("utf-8", "replace").strip()
            try:
                decoded = base64.b64decode(
                    raw + "=" * (-len(raw) % 4)
                ).decode("utf-8", "replace")
            except Exception:
                decoded = raw  # 有些订阅直接返回明文
            with open(CACHE_FILE, "w", encoding="utf-8") as f:
                f.write(decoded)
            return decoded
        except urllib.error.HTTPError as e:
            last_err = e
            if e.code == 429:
                break  # 被限流，重试无意义
            time.sleep(2 * (attempt + 1))
        except Exception as e:
            last_err = e
            time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"{last_err}")


def load_subscription(update=False):
    if not update and os.path.exists(CACHE_FILE):
        with open(CACHE_FILE, encoding="utf-8") as f:
            return f.read()
    try:
        return fetch_subscription()
    except Exception as e:
        if os.path.exists(CACHE_FILE):
            print(f"[提示] 更新订阅失败（{e}），改用本地缓存。", file=sys.stderr)
            with open(CACHE_FILE, encoding="utf-8") as f:
                return f.read()
        raise SystemExit(f"更新订阅失败且无本地缓存：{e}")


def parse_vless(line):
    """解析 vless://uuid@host:port?params#remark"""
    if not line.startswith("vless://"):
        return None
    body = line[len("vless://"):]
    remark = ""
    if "#" in body:
        body, remark = body.split("#", 1)
    remark = urllib.parse.unquote(remark).strip()

    userinfo, _, rest = body.partition("@")
    hostport, _, query = rest.partition("?")
    host, _, port = hostport.rpartition(":")
    if not host or not port.isdigit():
        return None
    q = dict(urllib.parse.parse_qsl(query))

    return {
        "uuid": userinfo,
        "address": host,
        "port": int(port),
        "name": remark,
        "net": q.get("type", "tcp"),
        "security": q.get("security", "none"),
        "sni": q.get("sni") or q.get("host") or host,
        "host": q.get("host", ""),
        "path": urllib.parse.unquote(q.get("path", "")),
        "fp": q.get("fp", "chrome"),
        "flow": q.get("flow", ""),
        "pbk": q.get("pbk", ""),
        "sid": q.get("sid", ""),
        "insecure": q.get("insecure") == "1",
    }


def load_nodes(update=False):
    nodes = []
    for line in load_subscription(update).splitlines():
        line = line.strip()
        if not line:
            continue
        n = parse_vless(line)
        if not n:
            continue
        if any(n["name"].startswith(p) for p in INFO_PREFIXES):
            continue
        nodes.append(n)
    return nodes


def build_config(node):
    """按节点生成完整 config.json（保留原有 inbound 与 routing）"""
    stream = {"network": node["net"], "security": node["security"]}
    fp = node["fp"] or "chrome"

    if node["security"] == "tls":
        tls = {"serverName": node["sni"], "fingerprint": fp}
        if node["insecure"]:
            tls["allowInsecure"] = True
        stream["tlsSettings"] = tls
    elif node["security"] == "reality":
        if not node["pbk"]:
            raise SystemExit("该节点是 reality 但缺少 pbk，无法使用。")
        stream["realitySettings"] = {
            "serverName": node["sni"],
            "publicKey": node["pbk"],
            "shortId": node["sid"],
            "fingerprint": fp,
            "spiderX": "/",
        }

    if node["net"] == "ws":
        ws = {"path": node["path"] or "/"}
        if node["host"]:
            ws["host"] = node["host"]
        stream["wsSettings"] = ws
    elif node["net"] == "grpc":
        stream["grpcSettings"] = {"serviceName": node["path"]}

    user = {"id": node["uuid"], "encryption": "none"}
    if node["flow"]:
        user["flow"] = node["flow"]

    return {
        "log": {"loglevel": "warning"},
        "inbounds": [
            {
                "tag": "socks-in",
                "listen": "127.0.0.1",
                "port": 10808,
                "protocol": "socks",
                "settings": {"udp": True},
                "sniffing": {"enabled": True, "destOverride": ["http", "tls"]},
            },
            {
                "tag": "http-in",
                "listen": "127.0.0.1",
                "port": 10809,
                "protocol": "http",
            },
        ],
        "outbounds": [
            {
                "tag": "proxy",
                "protocol": "vless",
                "settings": {
                    "vnext": [
                        {
                            "address": node["address"],
                            "port": node["port"],
                            "users": [user],
                        }
                    ]
                },
                "streamSettings": stream,
            },
            {"tag": "direct", "protocol": "freedom"},
            {"tag": "block", "protocol": "blackhole"},
        ],
        "routing": {
            "domainStrategy": "AsIs",
            "rules": [
                {"type": "field", "ip": ["geoip:private"], "outboundTag": "direct"}
            ],
        },
    }


def restart_xray():
    subprocess.run(["pkill", "-f", "xray run"], check=False)
    time.sleep(0.5)
    with open(os.path.join(XRAY_DIR, "xray.log"), "wb") as logf:
        subprocess.Popen(
            ["/usr/local/bin/xray", "run", "-c", CONFIG_FILE],
            cwd=XRAY_DIR,
            stdout=logf,
            stderr=logf,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
    # 等待端口就绪
    for _ in range(40):
        r = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "--max-time", "2",
             "-x", "http://127.0.0.1:10809", "http://cp.cloudflare.com/"],
            capture_output=True,
        )
        if r.returncode == 0:
            return True
        time.sleep(0.3)
    return False


def show_nodes(nodes, current=None):
    print(f"共 {len(nodes)} 个节点：\n")
    print(f"{'序号':<6}{'地区/名称':<34}{'类型':<18}{'安全'}")
    print("-" * 74)
    for i, n in enumerate(nodes, 1):
        marker = " *" if i == current else ""
        label = n["name"] or n["address"]
        typ = f"{n['net']}/{n['security']}"
        title = label.replace("|", " | ")
        print(f"{i:<6}{title:<34}{typ:<18}{'⚠insecure' if n['insecure'] else 'ok'}{marker}")
    print("\n切换命令：python3 ~/xray-node.py <序号>")


def main():
    args = [a for a in sys.argv[1:]]
    update = "-u" in args or "--update" in args
    nums = [a for a in args if a.isdigit()]

    # 仅更新订阅缓存，不打印节点列表（供开机脚本调用）
    if "-U" in args or "--update-only" in args:
        try:
            fetch_subscription()
        except Exception as e:
            print(f"订阅更新失败：{e}", file=sys.stderr)
            sys.exit(1)
        print(f"订阅已更新，共 {len(load_nodes(update=False))} 个节点。")
        return

    nodes = load_nodes(update=update)
    if not nodes:
        raise SystemExit("没有解析到任何节点，请检查订阅链接是否有效。")

    if not nums:
        show_nodes(nodes)
        return

    idx = int(nums[0])
    if not 1 <= idx <= len(nodes):
        raise SystemExit(f"序号超范围，应为 1-{len(nodes)}")

    node = nodes[idx - 1]
    cfg = build_config(node)

    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, "rb") as f:
            backup = f.read()
        with open(CONFIG_FILE + ".bak", "wb") as f:
            f.write(backup)

    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)

    print(f"已切换 -> [{idx}] {node['name']}")
    print(f"   {node['address']}:{node['port']}  {node['net']}/{node['security']}")
    if node["insecure"]:
        print("   ⚠ 该节点跳过证书校验(insecure)，安全性较低")

    if restart_xray():
        print("   xray 已重启并就绪 ✅")
    else:
        print("   ⚠ xray 启动后端口不通，请查看 xray.log")


if __name__ == "__main__":
    main()
