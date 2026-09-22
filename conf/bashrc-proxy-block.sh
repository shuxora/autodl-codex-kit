
# >>> autodl-codex-kit >>>（由 install.sh 自动追加，勿手改；改配置请重跑 install.sh）
# 统一入口：/root/startup.sh（开机也走同一套逻辑，幂等）
#   新终端自动开代理：touch ${XRAY_DIR:-/root/autodl-tmp/xray-core}/auto-proxy
#   取消自动开代理：  rm    ${XRAY_DIR:-/root/autodl-tmp/xray-core}/auto-proxy
if [ -f "${XRAY_DIR:-/root/autodl-tmp/xray-core}/auto-proxy" ]; then
    [ -f /root/proxy-on.sh ] && source /root/proxy-on.sh >/dev/null 2>&1
else
    [ -x /root/startup.sh ] && ( /root/startup.sh -q -n >/dev/null 2>&1 & )
fi
# <<< autodl-codex-kit <<<
