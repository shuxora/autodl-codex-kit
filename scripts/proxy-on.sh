#!/usr/bin/env bash
# 用法：source ~/proxy-on.sh
# 作用：确保 xray 已运行，并把代理环境变量导入当前 shell（仅当前会话生效）

XRAY_DIR="${XRAY_DIR:-/root/autodl-tmp/xray-core}"

if ! pgrep -f "xray run" >/dev/null 2>&1; then
  setsid nohup xray run -c "$XRAY_DIR/config.json" \
    > "$XRAY_DIR/xray.log" 2>&1 < /dev/null &
  echo "[proxy] xray 已启动，等待就绪..."
  for _ in $(seq 1 30); do
    curl -s -o /dev/null --max-time 2 -x http://127.0.0.1:10809 http://cp.cloudflare.com/ && break
    sleep 0.3
  done
else
  echo "[proxy] xray 已在运行"
fi

export http_proxy=http://127.0.0.1:10809
export https_proxy=http://127.0.0.1:10809
export all_proxy=socks5://127.0.0.1:10808
export no_proxy=localhost,127.0.0.1

if pgrep -f "xray run" >/dev/null 2>&1; then
  echo "[proxy] 已开启 -> HTTP 127.0.0.1:10809 / SOCKS5 127.0.0.1:10808"
else
  echo "[proxy] 警告：xray 启动失败，请查看 $XRAY_DIR/xray.log"
fi
echo "[proxy] 关闭请执行：source ~/proxy-off.sh"
