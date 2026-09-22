#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
节点测速/稳定性对比 —— 找出最适合跑 Codex 的节点

用法：
    python3 ~/xray-bench.py              # 测试默认候选节点
    python3 ~/xray-bench.py 8 25 26 16   # 测试指定序号
    python3 ~/xray-bench.py -n 3 8 25    # 每个节点测 3 次（默认 5 次）

测试完会自动恢复测速前的节点。
"""

import importlib.util
import json
import os
import subprocess
import sys
import time

# 复用 xray-node.py 里的解析/配置生成/重启逻辑
# 默认取安装位置 /root/xray-node.py，可用环境变量 XRAY_NODE_PY 覆盖
_spec = importlib.util.spec_from_file_location(
    "xraynode", os.environ.get("XRAY_NODE_PY", "/root/xray-node.py")
)
xn = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(xn)

PROXY = "http://127.0.0.1:10809"
CONFIG = "/root/autodl-tmp/xray-core/config.json"

# 默认候选：美国(0.1x)、日本 reality、新加坡、英国
DEFAULT_CANDIDATES = [25, 26, 16, 17, 8, 13, 21]


def curl(args, timeout=25):
    r = subprocess.run(
        ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code} %{time_starttransfer} %{speed_download}"]
         + args,
        capture_output=True, text=True, timeout=timeout + 10,
    )
    return r.stdout.strip().split()


def probe_latency(tries):
    """多次请求 api.openai.com，返回 (成功次数, 平均耗时, 失败次数)"""
    lat, fail = [], 0
    for _ in range(tries):
        t0 = time.time()
        try:
            out = curl(["-x", PROXY, "--max-time", "25",
                        "https://api.openai.com/v1/models"])
            code = out[0] if out else "000"
        except subprocess.TimeoutExpired:
            code = "000"
        dt = time.time() - t0
        # 只要收到了 HTTP 响应就说明链路通（401 表示打到服务器了）
        if code not in ("000", ""):
            lat.append(dt)
        else:
            fail += 1
    avg = sum(lat) / len(lat) if lat else 0.0
    return len(lat), avg, fail


def probe_speed():
    """下载 2MB 测吞吐（KB/s）"""
    try:
        out = curl(["-x", PROXY, "--max-time", "30",
                    "https://speed.cloudflare.com/__down?bytes=2000000"])
        return float(out[2]) / 1024 if len(out) > 2 else 0.0
    except Exception:
        return 0.0


def main():
    args = [a for a in sys.argv[1:]]
    tries = 5
    if "-n" in args:
        i = args.index("-n")
        tries = int(args[i + 1])
        del args[i:i + 2]
    indices = [int(a) for a in args if a.isdigit()] or DEFAULT_CANDIDATES

    nodes = xn.load_nodes(update=False)
    if not nodes:
        raise SystemExit("没有可用节点，请先运行：python3 ~/xray-node.py -u")

    original = xray_current_node(nodes)
    print(f"开始测速，共 {len(indices)} 个节点，每节点 {tries} 次请求\n")
    print(f"{'序号':<5}{'节点':<30}{'延迟(ms)':<11}{'失败':<7}{'吞吐(KB/s)':<12}{'评分'}")
    print("-" * 78)

    results = []
    for idx in indices:
        if not 1 <= idx <= len(nodes):
            continue
        node = nodes[idx - 1]
        try:
            cfg = xn.build_config(node)
        except SystemExit as e:
            print(f"{idx:<5}{node['name'][:28]:<30}{'跳过':<11}{'-':<7}{'-':<12}{e}")
            continue

        with open(CONFIG, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
        if not xn.restart_xray():
            print(f"{idx:<5}{node['name'][:28]:<30}{'启动失败':<11}")
            continue

        ok, avg, fail = probe_latency(tries)
        speed = probe_speed()
        score = (avg * 1000) + fail * 500 + (2000 / speed if speed > 0 else 3000)
        results.append((score, idx, node["name"], avg * 1000, fail, speed))

        print(f"{idx:<5}{node['name'][:28]:<30}{avg*1000:<11.0f}{fail:<7}{speed:<12.0f}{score:.0f}")

    if not results:
        raise SystemExit("\n所有节点测试均失败。")

    results.sort()
    print("\n=== 推荐（评分越低越好）===")
    for s, idx, name, ms, fail, sp in results[:3]:
        print(f"  {idx:>3}  {name:<30} {ms:.0f}ms  失败{fail}次  {sp:.0f}KB/s")

    best = results[0][1]
    print(f"\n切换最佳节点：python3 ~/xray-node.py {best}")

    # 恢复测速前的节点
    if original and original != best:
        print(f"（已自动恢复原节点 {original}，如需切换请手动执行上面的命令）")
        cfg = xn.build_config(nodes[original - 1])
        with open(CONFIG, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
        xn.restart_xray()


def xray_current_node(nodes):
    try:
        with open(CONFIG, encoding="utf-8") as f:
            cur = json.load(f)
        addr = cur["outbounds"][0]["settings"]["vnext"][0]["address"]
        port = cur["outbounds"][0]["settings"]["vnext"][0]["port"]
        for i, n in enumerate(nodes, 1):
            if n["address"] == addr and n["port"] == port:
                return i
    except Exception:
        pass
    return None


if __name__ == "__main__":
    main()
