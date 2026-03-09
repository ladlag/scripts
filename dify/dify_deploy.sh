#!/usr/bin/env bash
# =============================================================================
# dify_deploy.sh — 多机/多角色生产级 Dify Docker Compose 一键部署脚本
#
# 功能概述
# --------
#   1. 按角色（role）动态拼装 docker-compose.yml，无需手动维护多份文件。
#   2. 支持单机全量部署（all-in-one），也支持将角色分散到不同机器。
#   3. 支持 API 节点横向扩容（--api-replicas N）。
#   4. 内置 nginx upstream 配置生成，实现多 API/Worker 节点负载均衡。
#   5. 提供健康检查、日志查看、滚动升级等常用运维命令。
#
# 支持角色（--role 可多次使用，或用逗号分隔）
# -----------------------------------------------
#   infrastructure  PostgreSQL + Redis + Weaviate（向量库）+ Sandbox + SSRF Proxy
#   api             Dify API Server
#   worker          Dify Celery Worker
#   web             Dify Web Frontend
#   nginx           Nginx 反向代理 / 负载均衡入口
#   all             以上全部（单机 all-in-one，默认值）
#
# 使用示例
# --------
#   # 1. 单机 all-in-one 快速启动
#   bash dify_deploy.sh up
#
#   # 2. 基础设施节点（机器 A）
#   bash dify_deploy.sh --role infrastructure up
#
#   # 3. API + Worker 节点（机器 B），扩容到 3 个 API 副本
#   bash dify_deploy.sh --role api,worker --api-replicas 3 up
#
#   # 4. Web + Nginx 节点（机器 C），nginx 上游指向多个 API 机器
#   bash dify_deploy.sh --role web,nginx \
#       --nginx-api-upstreams "192.168.1.11:5001 192.168.1.12:5001" \
#       up
#
#   # 5. 查看运行状态
#   bash dify_deploy.sh status
#
#   # 6. 滚动升级（拉取最新镜像后重启）
#   bash dify_deploy.sh upgrade
#
#   # 7. 停止并移除容器（保留数据卷）
#   bash dify_deploy.sh down
#
# 依赖
# ----
#   - Docker >= 20.10  (支持 compose plugin 或 docker-compose v2)
#   - deploy.env       (与本脚本同目录，或通过 --env-file 指定)
#
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. 全局常量与默认值
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 环境变量配置文件默认路径（支持 --env-file 覆盖）
ENV_FILE="${SCRIPT_DIR}/deploy.env"

# 生成的 compose 文件输出目录（每次部署时动态生成）
COMPOSE_DIR="${SCRIPT_DIR}/.compose"

# Dify 官方镜像仓库
DIFY_IMAGE_API="langgenius/dify-api"
DIFY_IMAGE_WEB="langgenius/dify-web"
DIFY_IMAGE_SANDBOX="langgenius/dify-sandbox"

# 默认版本号（可在 deploy.env 中通过 DIFY_VERSION 覆盖）
DIFY_VERSION="${DIFY_VERSION:-0.15.3}"

# 默认角色为 all（单机全量部署）
ROLES="all"

# API 副本数，默认 1
API_REPLICAS=1

# Nginx 上游 API 节点列表（空格分隔的 host:port），默认指向本机
NGINX_API_UPSTREAMS=""

# compose 命令自动探测（优先使用 docker compose plugin）
if docker compose version &>/dev/null; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
    DOCKER_COMPOSE="docker-compose"
else
    echo "[ERROR] 未找到 docker compose 或 docker-compose，请先安装 Docker >= 20.10" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. 参数解析
# ---------------------------------------------------------------------------
COMMAND=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --role)
                ROLES="$2"; shift 2 ;;
            --role=*)
                ROLES="${1#--role=}"; shift ;;
            --api-replicas)
                API_REPLICAS="$2"; shift 2 ;;
            --api-replicas=*)
                API_REPLICAS="${1#--api-replicas=}"; shift ;;
            --nginx-api-upstreams)
                NGINX_API_UPSTREAMS="$2"; shift 2 ;;
            --nginx-api-upstreams=*)
                NGINX_API_UPSTREAMS="${1#--nginx-api-upstreams=}"; shift ;;
            --env-file)
                ENV_FILE="$2"; shift 2 ;;
            --env-file=*)
                ENV_FILE="${1#--env-file=}"; shift ;;
            up|down|status|logs|upgrade|restart|ps)
                COMMAND="$1"; shift ;;
            -h|--help)
                usage; exit 0 ;;
            *)
                echo "[WARN] 未知参数: $1，已忽略" >&2; shift ;;
        esac
    done

    # 默认命令为 up
    COMMAND="${COMMAND:-up}"
}

usage() {
    sed -n '/^# 使用示例/,/^# 依赖/p' "${BASH_SOURCE[0]}" | grep -v '^#\s*$' | sed 's/^# //'
}

# ---------------------------------------------------------------------------
# 2. 环境变量加载
# ---------------------------------------------------------------------------
load_env() {
    if [[ ! -f "${ENV_FILE}" ]]; then
        echo "[ERROR] 环境变量文件不存在: ${ENV_FILE}" >&2
        echo "        请复制 deploy.env 为 deploy.env.local，填写所有 [必填] 项后使用 --env-file deploy.env.local 启动" >&2
        echo "        示例：bash dify_deploy.sh --env-file deploy.env.local up" >&2
        exit 1
    fi
    # 仅导出非注释、非空行的变量（不覆盖已有 shell 环境变量）
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
    echo "[INFO] 已加载环境变量: ${ENV_FILE}"
}

# ---------------------------------------------------------------------------
# 3. 角色解析 —— 将逗号/空格分隔的角色字符串展开为数组
# ---------------------------------------------------------------------------
declare -A ROLE_MAP   # role_name -> 1

parse_roles() {
    # 将逗号替换为空格，再分割
    local role_str="${ROLES//,/ }"
    local valid_roles=" infrastructure api worker web nginx all "
    for r in ${role_str}; do
        if [[ "${valid_roles}" != *" ${r} "* ]]; then
            echo "[WARN] 未知角色: '${r}'，已忽略。有效角色: infrastructure api worker web nginx all" >&2
        else
            ROLE_MAP["${r}"]=1
        fi
    done

    # "all" 展开为全部角色
    if [[ -n "${ROLE_MAP[all]+x}" ]]; then
        ROLE_MAP=()
        for r in infrastructure api worker web nginx; do
            ROLE_MAP["${r}"]=1
        done
    fi

    if [[ "${#ROLE_MAP[@]}" -eq 0 ]]; then
        echo "[ERROR] 未指定任何有效角色，请使用 --role 指定角色" >&2
        exit 1
    fi

    echo "[INFO] 本机部署角色: ${!ROLE_MAP[*]}"
}

has_role() { [[ -n "${ROLE_MAP[$1]+x}" ]]; }

# ---------------------------------------------------------------------------
# 4. Compose 文件生成
# ---------------------------------------------------------------------------

# --- 4.1 公共头部（版本声明、网络、数据卷）---
gen_compose_header() {
    cat <<'EOF'
# 本文件由 dify_deploy.sh 自动生成，请勿手动修改。
# 如需定制，请修改 dify_deploy.sh 中对应的生成函数。

networks:
  dify:
    driver: bridge

volumes:
  dify_db_data:
  dify_redis_data:
  dify_weaviate_data:
  dify_storage:

services:
EOF
}

# --- 4.2 基础设施服务（PostgreSQL / Redis / Weaviate / Sandbox / SSRF Proxy）---
gen_service_infrastructure() {
    cat <<EOF
  # ------------------------------------------------------------------
  # PostgreSQL：Dify 主数据库，存储用户、应用、对话等结构化数据
  # ------------------------------------------------------------------
  db:
    image: postgres:15-alpine
    restart: always
    environment:
      PGUSER: \${POSTGRES_USER:-dify}
      POSTGRES_USER: \${POSTGRES_USER:-dify}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD:?POSTGRES_PASSWORD 必须设置}
      POSTGRES_DB: \${POSTGRES_DB:-dify}
      PGDATA: /var/lib/postgresql/data/pgdata
    command: >
      postgres
        -c max_connections=\${POSTGRES_MAX_CONNECTIONS:-200}
        -c shared_buffers=\${POSTGRES_SHARED_BUFFERS:-512MB}
        -c work_mem=\${POSTGRES_WORK_MEM:-16MB}
        -c maintenance_work_mem=\${POSTGRES_MAINTENANCE_WORK_MEM:-64MB}
        -c effective_cache_size=\${POSTGRES_EFFECTIVE_CACHE_SIZE:-2GB}
        -c wal_level=replica
        -c archive_mode=off
    volumes:
      - dify_db_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER:-dify} -d \${POSTGRES_DB:-dify}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    networks:
      - dify

  # ------------------------------------------------------------------
  # Redis：任务队列、缓存、Pub/Sub
  # ------------------------------------------------------------------
  redis:
    image: redis:7-alpine
    restart: always
    command: >
      redis-server
        --requirepass \${REDIS_PASSWORD:?REDIS_PASSWORD 必须设置}
        --maxmemory \${REDIS_MAX_MEMORY:-512mb}
        --maxmemory-policy allkeys-lru
        --save 60 1
        --appendonly yes
        --appendfsync everysec
    volumes:
      - dify_redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "\${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s
    networks:
      - dify

  # ------------------------------------------------------------------
  # Weaviate：向量数据库，存储文档 embedding
  # ------------------------------------------------------------------
  weaviate:
    image: semitechnologies/weaviate:1.24.6
    restart: always
    environment:
      AUTHENTICATION_APIKEY_ENABLED: "true"
      AUTHENTICATION_APIKEY_ALLOWED_KEYS: \${WEAVIATE_API_KEY:?WEAVIATE_API_KEY 必须设置}
      AUTHENTICATION_APIKEY_USERS: dify
      AUTHORIZATION_ADMINLIST_ENABLED: "true"
      AUTHORIZATION_ADMINLIST_USERS: dify
      DEFAULT_VECTORIZER_MODULE: none
      CLUSTER_HOSTNAME: weaviate-node
      PERSISTENCE_DATA_PATH: /var/lib/weaviate
      ENABLE_MODULES: ""
      QUERY_DEFAULTS_LIMIT: 25
    volumes:
      - dify_weaviate_data:/var/lib/weaviate
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:8080/v1/.well-known/ready"]
      interval: 15s
      timeout: 10s
      retries: 5
      start_period: 30s
    networks:
      - dify

  # ------------------------------------------------------------------
  # Sandbox：隔离代码执行环境（供 Dify Code Block 使用）
  # ------------------------------------------------------------------
  sandbox:
    image: ${DIFY_IMAGE_SANDBOX}:${DIFY_VERSION}
    restart: always
    environment:
      API_KEY: \${SANDBOX_API_KEY:?SANDBOX_API_KEY 必须设置}
      GIN_MODE: release
      WORKER_TIMEOUT: \${SANDBOX_WORKER_TIMEOUT:-15}
      ENABLE_NETWORK: \${SANDBOX_ENABLE_NETWORK:-false}
      HTTP_PROXY: \${SSRF_HTTP_PROXY:-http://ssrf_proxy:3128}
      HTTPS_PROXY: \${SSRF_HTTPS_PROXY:-http://ssrf_proxy:3128}
      SANDBOX_PORT: 8194
    networks:
      - dify

  # ------------------------------------------------------------------
  # SSRF Proxy：防止服务端请求伪造的出站代理
  # 配置文件位于 ssrf_proxy/squid.conf.template（相对于 dify/ 目录）
  # ------------------------------------------------------------------
  ssrf_proxy:
    image: ubuntu/squid:latest
    restart: always
    volumes:
      - ../ssrf_proxy/squid.conf.template:/etc/squid/squid.conf.template
      - ../ssrf_proxy/docker-entrypoint.sh:/docker-entrypoint-mount.sh
    entrypoint: >
      sh -c "
        cp /docker-entrypoint-mount.sh /docker-entrypoint.sh &&
        sed -i 's/\\r//' /docker-entrypoint.sh &&
        chmod +x /docker-entrypoint.sh &&
        /docker-entrypoint.sh
      "
    environment:
      SQUID_HTTP_PORT: 3128
      COREDUMP_DIR: /var/spool/squid
    networks:
      - dify

EOF
}

# --- 4.3 API 服务 ---
gen_service_api() {
    # 当 API_REPLICAS > 1 时，不指定固定端口映射（由 nginx 代理），
    # 并设置 deploy.replicas（仅 swarm 模式下生效；compose 下用 scale 命令）
    local port_mapping=""
    if [[ "${API_REPLICAS}" -eq 1 ]]; then
        port_mapping="    ports:
      - \"\${API_BIND_HOST:-127.0.0.1}:\${API_PORT:-5001}:5001\""
    fi

    # depends_on 只列出本机 compose 文件中实际存在的服务，
    # 避免多机部署时（无 infrastructure 角色）引发 "undefined service" 错误
    local depends_block=""
    if has_role infrastructure; then
        depends_block="    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy"
    fi

    cat <<EOF
  # ------------------------------------------------------------------
  # API Server：Dify 后端 REST API，处理所有业务逻辑请求
  # 生产建议：通过 nginx 代理，此处不直接对外暴露端口
  # ------------------------------------------------------------------
  api:
    image: ${DIFY_IMAGE_API}:\${DIFY_VERSION:-${DIFY_VERSION}}
    restart: always
${port_mapping}
    environment:
      # 运行模式
      MODE: api
      LOG_LEVEL: \${LOG_LEVEL:-INFO}
      DEBUG: \${DEBUG:-false}

      # 密钥（每个节点保持一致！首次部署后请勿更改）
      SECRET_KEY: \${SECRET_KEY:?SECRET_KEY 必须设置}

      # 数据库
      DB_USERNAME: \${POSTGRES_USER:-dify}
      DB_PASSWORD: \${POSTGRES_PASSWORD}
      DB_HOST: \${POSTGRES_HOST:-db}
      DB_PORT: \${POSTGRES_PORT:-5432}
      DB_DATABASE: \${POSTGRES_DB:-dify}

      # Redis
      REDIS_HOST: \${REDIS_HOST:-redis}
      REDIS_PORT: \${REDIS_PORT:-6379}
      REDIS_PASSWORD: \${REDIS_PASSWORD}
      REDIS_DB: 0

      # Celery Broker（复用 Redis）
      CELERY_BROKER_URL: redis://:\${REDIS_PASSWORD}@\${REDIS_HOST:-redis}:\${REDIS_PORT:-6379}/1
      BROKER_USE_SSL: \${BROKER_USE_SSL:-false}

      # 向量数据库
      VECTOR_STORE: \${VECTOR_STORE:-weaviate}
      WEAVIATE_ENDPOINT: http://\${WEAVIATE_HOST:-weaviate}:8080
      WEAVIATE_API_KEY: \${WEAVIATE_API_KEY}

      # 文件存储（local / s3 / azure-blob / google-storage）
      STORAGE_TYPE: \${STORAGE_TYPE:-local}
      STORAGE_LOCAL_PATH: /app/api/storage
      S3_ENDPOINT: \${S3_ENDPOINT:-}
      S3_BUCKET_NAME: \${S3_BUCKET_NAME:-}
      S3_ACCESS_KEY: \${S3_ACCESS_KEY:-}
      S3_SECRET_KEY: \${S3_SECRET_KEY:-}
      S3_REGION: \${S3_REGION:-}

      # Sandbox
      CODE_EXECUTION_ENDPOINT: http://\${SANDBOX_HOST:-sandbox}:8194
      CODE_EXECUTION_API_KEY: \${SANDBOX_API_KEY}
      CODE_MAX_NUMBER: \${CODE_MAX_NUMBER:-9223372036854775807}
      CODE_MIN_NUMBER: \${CODE_MIN_NUMBER:--9223372036854775808}
      CODE_MAX_STRING_LENGTH: \${CODE_MAX_STRING_LENGTH:-80000}
      CODE_MAX_OBJECT_ARRAY_LENGTH: \${CODE_MAX_OBJECT_ARRAY_LENGTH:-30}
      CODE_MAX_STRING_ARRAY_LENGTH: \${CODE_MAX_STRING_ARRAY_LENGTH:-30}
      CODE_MAX_NUMBER_ARRAY_LENGTH: \${CODE_MAX_NUMBER_ARRAY_LENGTH:-1000}

      # 邮件（可选）
      MAIL_TYPE: \${MAIL_TYPE:-}
      RESEND_API_KEY: \${RESEND_API_KEY:-}
      MAIL_DEFAULT_SEND_FROM: \${MAIL_DEFAULT_SEND_FROM:-}
      SMTP_SERVER: \${SMTP_SERVER:-}
      SMTP_PORT: \${SMTP_PORT:-465}
      SMTP_USERNAME: \${SMTP_USERNAME:-}
      SMTP_PASSWORD: \${SMTP_PASSWORD:-}
      SMTP_USE_TLS: \${SMTP_USE_TLS:-true}
      SMTP_OPPORTUNISTIC_TLS: \${SMTP_OPPORTUNISTIC_TLS:-false}

      # 服务基础 URL（nginx 对外地址）
      CONSOLE_WEB_URL: \${CONSOLE_WEB_URL:-}
      CONSOLE_API_URL: \${CONSOLE_API_URL:-}
      SERVICE_API_URL: \${SERVICE_API_URL:-}
      APP_WEB_URL: \${APP_WEB_URL:-}

      # SSRF 代理（出站 HTTP 请求经由 squid，防 Server-Side Request Forgery）
      SSRF_PROXY_HTTP_URL: \${SSRF_PROXY_HTTP_URL:-http://ssrf_proxy:3128}
      SSRF_PROXY_HTTPS_URL: \${SSRF_PROXY_HTTPS_URL:-http://ssrf_proxy:3128}

      # 文件上传限制
      UPLOAD_FILE_SIZE_LIMIT: \${UPLOAD_FILE_SIZE_LIMIT:-15}
      UPLOAD_FILE_BATCH_LIMIT: \${UPLOAD_FILE_BATCH_LIMIT:-5}
      UPLOAD_IMAGE_FILE_SIZE_LIMIT: \${UPLOAD_IMAGE_FILE_SIZE_LIMIT:-10}
    volumes:
      - dify_storage:/app/api/storage
${depends_block}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5001/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    networks:
      - dify
    deploy:
      replicas: ${API_REPLICAS}
      restart_policy:
        condition: on-failure
        max_attempts: 3

EOF
}

# --- 4.4 Worker 服务 ---
gen_service_worker() {
    # depends_on 只列出本机实际存在的服务（多机部署时 db/redis 在远端）
    local depends_block=""
    if has_role infrastructure; then
        depends_block="    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy"
    fi

    cat <<EOF
  # ------------------------------------------------------------------
  # Celery Worker：异步任务处理（文档索引、模型推理队列等）
  # 可根据负载在多台机器上部署多个 worker
  # ------------------------------------------------------------------
  worker:
    image: ${DIFY_IMAGE_API}:\${DIFY_VERSION:-${DIFY_VERSION}}
    restart: always
    environment:
      # worker 模式（与 api 共用同一镜像，通过 MODE 区分）
      MODE: worker
      LOG_LEVEL: \${LOG_LEVEL:-INFO}
      DEBUG: \${DEBUG:-false}

      # 密钥（须与 API 节点保持一致）
      SECRET_KEY: \${SECRET_KEY:?SECRET_KEY 必须设置}

      # 数据库
      DB_USERNAME: \${POSTGRES_USER:-dify}
      DB_PASSWORD: \${POSTGRES_PASSWORD}
      DB_HOST: \${POSTGRES_HOST:-db}
      DB_PORT: \${POSTGRES_PORT:-5432}
      DB_DATABASE: \${POSTGRES_DB:-dify}

      # Redis
      REDIS_HOST: \${REDIS_HOST:-redis}
      REDIS_PORT: \${REDIS_PORT:-6379}
      REDIS_PASSWORD: \${REDIS_PASSWORD}
      REDIS_DB: 0

      # Celery Broker
      CELERY_BROKER_URL: redis://:\${REDIS_PASSWORD}@\${REDIS_HOST:-redis}:\${REDIS_PORT:-6379}/1
      BROKER_USE_SSL: \${BROKER_USE_SSL:-false}

      # 向量数据库
      VECTOR_STORE: \${VECTOR_STORE:-weaviate}
      WEAVIATE_ENDPOINT: http://\${WEAVIATE_HOST:-weaviate}:8080
      WEAVIATE_API_KEY: \${WEAVIATE_API_KEY}

      # 文件存储
      STORAGE_TYPE: \${STORAGE_TYPE:-local}
      STORAGE_LOCAL_PATH: /app/api/storage
      S3_ENDPOINT: \${S3_ENDPOINT:-}
      S3_BUCKET_NAME: \${S3_BUCKET_NAME:-}
      S3_ACCESS_KEY: \${S3_ACCESS_KEY:-}
      S3_SECRET_KEY: \${S3_SECRET_KEY:-}
      S3_REGION: \${S3_REGION:-}

      # Sandbox
      CODE_EXECUTION_ENDPOINT: http://\${SANDBOX_HOST:-sandbox}:8194
      CODE_EXECUTION_API_KEY: \${SANDBOX_API_KEY}

      # SSRF 代理
      SSRF_PROXY_HTTP_URL: \${SSRF_PROXY_HTTP_URL:-http://ssrf_proxy:3128}
      SSRF_PROXY_HTTPS_URL: \${SSRF_PROXY_HTTPS_URL:-http://ssrf_proxy:3128}

      # Worker 并发数
      CELERY_WORKER_AMOUNT: \${CELERY_WORKER_AMOUNT:-}
      CELERY_AUTO_SCALE: \${CELERY_AUTO_SCALE:-false}
      CELERY_MAX_WORKERS: \${CELERY_MAX_WORKERS:-4}
      CELERY_MIN_WORKERS: \${CELERY_MIN_WORKERS:-1}
    volumes:
      - dify_storage:/app/api/storage
${depends_block}
    networks:
      - dify

EOF
}

# --- 4.5 Web 前端 ---
gen_service_web() {
    cat <<EOF
  # ------------------------------------------------------------------
  # Web Frontend：Dify 控制台 + 应用 Web 前端（Next.js）
  # ------------------------------------------------------------------
  web:
    image: ${DIFY_IMAGE_WEB}:\${DIFY_VERSION:-${DIFY_VERSION}}
    restart: always
    environment:
      CONSOLE_API_URL: \${CONSOLE_API_URL:-}
      APP_API_URL: \${APP_API_URL:-}
      NEXT_TELEMETRY_DISABLED: "1"
    networks:
      - dify

EOF
}

# --- 4.6 Nginx 反向代理 ---
gen_service_nginx() {
    # depends_on 只列出本机 compose 文件中实际存在的服务，
    # 避免多机部署时 nginx 单独部署引发 "undefined service" 错误
    local depends_block=""
    if has_role api || has_role web; then
        depends_block="    depends_on:"
        has_role api && depends_block+=$'\n'"      - api"
        has_role web && depends_block+=$'\n'"      - web"
    fi

    cat <<EOF
  # ------------------------------------------------------------------
  # Nginx：SSL 终止、静态文件、反向代理 API 与 Web
  # 生产建议：在此终止 HTTPS，证书挂载到 /etc/nginx/ssl/
  # ------------------------------------------------------------------
  nginx:
    image: nginx:1.25-alpine
    restart: always
    ports:
      - "\${NGINX_HTTP_PORT:-80}:80"
      - "\${NGINX_HTTPS_PORT:-443}:443"
    volumes:
      - \${NGINX_CONF_DIR:-./nginx}:/etc/nginx/conf.d:ro
      - \${NGINX_SSL_DIR:-./ssl}:/etc/nginx/ssl:ro
      - \${NGINX_LOG_DIR:-./logs/nginx}:/var/log/nginx
${depends_block}
    networks:
      - dify

EOF
}

# --- 4.7 生成 nginx 配置文件 ---
gen_nginx_conf() {
    local nginx_dir="${COMPOSE_DIR}/nginx"
    mkdir -p "${nginx_dir}"

    # 构建 upstream 服务器列表
    local upstream_block="    server api:5001 fail_timeout=10s max_fails=3;"
    if [[ -n "${NGINX_API_UPSTREAMS}" ]]; then
        upstream_block=""
        for node in ${NGINX_API_UPSTREAMS}; do
            upstream_block+="    server ${node} fail_timeout=10s max_fails=3;"$'\n'
        done
    fi

    cat >"${nginx_dir}/dify.conf" <<EOF
# dify.conf — 由 dify_deploy.sh 自动生成
# 如需自定义请在 deploy.env 中设置 NGINX_CONF_DIR 指向自定义目录

# API / Worker 上游节点池（支持多 API 机器负载均衡）
upstream dify_api_upstream {
    # 负载均衡策略：least_conn 适合长连接/流式响应
    least_conn;
${upstream_block}
    keepalive 64;
}

# Web 前端上游（通常为单节点，可按需扩展）
upstream dify_web_upstream {
    server web:3000 fail_timeout=10s max_fails=3;
    keepalive 32;
}

# HTTP → HTTPS 重定向（如未启用 HTTPS 则删除此 server 块）
server {
    listen 80;
    server_name ${NGINX_SERVER_NAME:-_};
    # 如已配置证书，取消以下注释
    # return 301 https://\$host\$request_uri;

    # 不启用 HTTPS 时直接反代（开发/内网环境）
    include /etc/nginx/conf.d/dify_proxy.conf;
}

# HTTPS 服务（生产必须启用）
# server {
#     listen 443 ssl http2;
#     server_name ${NGINX_SERVER_NAME:-your.domain.com};
#
#     ssl_certificate     /etc/nginx/ssl/fullchain.pem;
#     ssl_certificate_key /etc/nginx/ssl/privkey.pem;
#     ssl_protocols       TLSv1.2 TLSv1.3;
#     ssl_ciphers         HIGH:!aNULL:!MD5;
#     ssl_session_cache   shared:SSL:10m;
#     ssl_session_timeout 10m;
#
#     include /etc/nginx/conf.d/dify_proxy.conf;
# }
EOF

    # 拆分公共代理配置，便于 HTTP/HTTPS server 块复用
    cat >"${nginx_dir}/dify_proxy.conf" <<'PROXYEOF'
# dify_proxy.conf — 通用代理规则，由 HTTP/HTTPS server 块 include

client_max_body_size 100M;
proxy_read_timeout   600s;
proxy_send_timeout   600s;
proxy_connect_timeout 60s;

# 公共代理请求头
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_http_version 1.1;
proxy_set_header Connection "";  # 开启 HTTP keepalive upstream

# SSE / 流式响应专用路由（必须在通用 location 之前声明，nginx 按最长前缀匹配）
# 匹配 Dify 所有流式 SSE 端点，禁止 nginx 缓冲，避免流式内容被攒够再发送
location = /v1/chat-messages {
    proxy_pass        http://dify_api_upstream;
    proxy_buffering   off;
    proxy_cache       off;
    proxy_read_timeout 3600s;
    proxy_set_header  Connection "";
    chunked_transfer_encoding on;
}

location = /v1/completion-messages {
    proxy_pass        http://dify_api_upstream;
    proxy_buffering   off;
    proxy_cache       off;
    proxy_read_timeout 3600s;
    proxy_set_header  Connection "";
    chunked_transfer_encoding on;
}

location = /v1/workflows/run {
    proxy_pass        http://dify_api_upstream;
    proxy_buffering   off;
    proxy_cache       off;
    proxy_read_timeout 3600s;
    proxy_set_header  Connection "";
    chunked_transfer_encoding on;
}

# console SSE endpoints
location ~ ^/console/api/apps/[a-zA-Z0-9_-]+/(chat-messages|completion-messages|workflows/run)$ {
    proxy_pass        http://dify_api_upstream;
    proxy_buffering   off;
    proxy_cache       off;
    proxy_read_timeout 3600s;
    proxy_set_header  Connection "";
    chunked_transfer_encoding on;
}

# API 路由（通用，含 buffering）
location /console/api {
    proxy_pass http://dify_api_upstream;
}

location /api {
    proxy_pass http://dify_api_upstream;
}

location /v1 {
    proxy_pass http://dify_api_upstream;
}

location /files {
    proxy_pass http://dify_api_upstream;
}

# Web 前端
location / {
    proxy_pass http://dify_web_upstream;
}
PROXYEOF

    echo "[INFO] nginx 配置已生成: ${nginx_dir}/dify.conf"
}

# --- 4.8 主 compose 文件拼装 ---
gen_compose_file() {
    mkdir -p "${COMPOSE_DIR}"
    local compose_file="${COMPOSE_DIR}/docker-compose.yml"

    {
        gen_compose_header
        has_role infrastructure && gen_service_infrastructure
        has_role api            && gen_service_api
        has_role worker         && gen_service_worker
        has_role web            && gen_service_web
        has_role nginx          && gen_service_nginx
    } >"${compose_file}"

    # 生成 nginx 配置文件（仅当本机包含 nginx 角色时）
    if has_role nginx; then
        gen_nginx_conf
    fi

    echo "[INFO] Compose 文件已生成: ${compose_file}"
}

# ---------------------------------------------------------------------------
# 5. compose 命令封装
# ---------------------------------------------------------------------------
compose_cmd() {
    local compose_file="${COMPOSE_DIR}/docker-compose.yml"
    ${DOCKER_COMPOSE} \
        --project-name dify \
        --env-file "${ENV_FILE}" \
        -f "${compose_file}" \
        "$@"
}

# ---------------------------------------------------------------------------
# 6. 各子命令实现
# ---------------------------------------------------------------------------

cmd_up() {
    echo "[INFO] 启动 Dify 服务..."
    if has_role api && [[ "${API_REPLICAS}" -gt 1 ]]; then
        echo "[INFO] API 服务将以 ${API_REPLICAS} 个副本启动..."
        compose_cmd up -d --remove-orphans --scale api="${API_REPLICAS}"
    else
        compose_cmd up -d --remove-orphans
    fi

    echo "[INFO] 服务已启动，运行状态："
    compose_cmd ps
}

cmd_down() {
    echo "[INFO] 停止并移除容器（数据卷保留）..."
    compose_cmd down --remove-orphans
}

cmd_status() {
    compose_cmd ps
}

cmd_logs() {
    # 默认显示最近 100 行并持续跟随
    compose_cmd logs --tail=100 -f
}

cmd_upgrade() {
    echo "[INFO] 拉取最新镜像..."
    compose_cmd pull

    echo "[INFO] 滚动重启服务..."
    # 先重启无状态服务，最后重启基础设施（避免数据库意外重启）
    for svc in api worker web nginx; do
        if compose_cmd ps "${svc}" &>/dev/null; then
            compose_cmd up -d --no-deps "${svc}"
            echo "[INFO] ${svc} 已更新"
        fi
    done

    echo "[INFO] 升级完成，当前状态："
    compose_cmd ps
}

cmd_restart() {
    compose_cmd restart
}

cmd_ps() {
    compose_cmd ps
}

# ---------------------------------------------------------------------------
# 7. 部署前检查
# ---------------------------------------------------------------------------
pre_flight_check() {
    echo "[INFO] 运行部署前检查..."

    # 检查 Docker 版本
    local docker_version
    docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0.0.0")
    local major
    major=$(echo "${docker_version}" | cut -d. -f1)
    if [[ "${major}" -lt 20 ]]; then
        echo "[WARN] Docker 版本 ${docker_version} 较旧，建议升级到 20.10+" >&2
    fi

    # 检查必须设置的环境变量
    local required_vars=(
        SECRET_KEY
        POSTGRES_PASSWORD
        REDIS_PASSWORD
        WEAVIATE_API_KEY
        SANDBOX_API_KEY
    )
    local missing=0
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            echo "[ERROR] 必须设置环境变量: ${var}" >&2
            missing=$((missing + 1))
        fi
    done
    if [[ "${missing}" -gt 0 ]]; then
        echo "[ERROR] 存在 ${missing} 个未设置的必要变量，请检查 ${ENV_FILE}" >&2
        exit 1
    fi

    # 检测示例占位符值（用户忘记替换 CHANGE_ME_ 前缀）
    local placeholder_found=0
    for var in "${required_vars[@]}"; do
        if [[ "${!var:-}" == CHANGE_ME_* ]]; then
            echo "[ERROR] 变量 ${var} 仍为示例占位符值，请替换为真实密钥" >&2
            placeholder_found=$((placeholder_found + 1))
        fi
    done
    if [[ "${placeholder_found}" -gt 0 ]]; then
        echo "[ERROR] 请编辑 ${ENV_FILE}，将所有 CHANGE_ME_* 替换为实际生成的密钥" >&2
        echo "        密钥生成示例：openssl rand -hex 32" >&2
        exit 1
    fi

    # 检查 SECRET_KEY 长度（建议 >= 32 字节）
    if [[ "${#SECRET_KEY}" -lt 32 ]]; then
        echo "[WARN] SECRET_KEY 长度不足 32 字符，生产环境请使用更强的密钥" >&2
        echo "       生成命令：openssl rand -hex 32" >&2
    fi

    echo "[INFO] 前置检查通过"
}

# ---------------------------------------------------------------------------
# 8. 主入口
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    load_env
    parse_roles

    echo "[INFO] 命令: ${COMMAND}"
    echo "[INFO] API 副本数: ${API_REPLICAS}"

    # 生成 compose 文件（所有命令都需要最新的 compose 文件）
    gen_compose_file

    case "${COMMAND}" in
        up)
            pre_flight_check
            cmd_up
            ;;
        down)      cmd_down ;;
        status|ps) cmd_status ;;
        logs)      cmd_logs ;;
        upgrade)
            pre_flight_check
            cmd_upgrade
            ;;
        restart)   cmd_restart ;;
        *)
            echo "[ERROR] 未知命令: ${COMMAND}" >&2
            usage
            exit 1
            ;;
    esac
}

main "$@"
