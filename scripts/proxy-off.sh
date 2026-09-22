#!/usr/bin/env bash
# 用法：source ~/proxy-off.sh
unset http_proxy https_proxy all_proxy no_proxy
echo "[proxy] 已关闭（xray 进程仍在后台，可保留）"
