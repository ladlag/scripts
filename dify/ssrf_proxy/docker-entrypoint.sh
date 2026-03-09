#!/bin/sh
# =============================================================================
# docker-entrypoint.sh — Dify SSRF Proxy (Squid) 启动脚本
#
# 流程：
#   1. 将 squid.conf.template 中的环境变量替换，生成 squid.conf
#   2. 确保日志目录权限正确
#   3. 以前台模式启动 Squid
# =============================================================================
set -e

SQUID_HTTP_PORT="${SQUID_HTTP_PORT:-3128}"
COREDUMP_DIR="${COREDUMP_DIR:-/var/spool/squid}"

echo "[ssrf_proxy] 生成 squid.conf（监听端口: ${SQUID_HTTP_PORT}）..."

# 使用 envsubst 替换模板变量（ubuntu/squid 镜像内置 gettext-base 包含 envsubst）
export SQUID_HTTP_PORT COREDUMP_DIR
envsubst < /etc/squid/squid.conf.template > /etc/squid/squid.conf

# 初始化 Squid 缓存目录（首次启动需要）
if [ ! -d "${COREDUMP_DIR}/00" ]; then
    echo "[ssrf_proxy] 初始化 Squid 缓存目录..."
    squid -N -f /etc/squid/squid.conf -z 2>/dev/null || true
fi

# 确保日志目录存在且权限正确
mkdir -p /var/log/squid
chown -R proxy:proxy /var/log/squid 2>/dev/null || true

echo "[ssrf_proxy] 启动 Squid SSRF 防护代理..."
exec squid -N -f /etc/squid/squid.conf
