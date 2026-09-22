#!/bin/bash
# ============================================================================
# AutoDL 容器开机启动钩子（由 autodl-codex-kit 维护）
#
# 调用链：supervisord(customer-cmd) -> /init/bin/customer.cmd.sh -> 本文件
# 说明：本文件在系统盘，保存镜像时会保留；重置系统后需重跑 install.sh。
#       日志：/tmp/autodl-startup.log（-u 会先更新订阅再启动）
# ============================================================================

if [ -x /root/startup.sh ]; then
    bash /root/startup.sh -u >> /tmp/autodl-startup.log 2>&1
fi
