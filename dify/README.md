# Dify 多机生产级 Docker Compose 部署指南

本目录提供 **生产就绪** 的 Dify 多机 / 多角色 Docker Compose 部署方案，支持：

- 单机 all-in-one 快速启动（开发 / 测试）
- 多机分角色部署（基础设施 / API / Worker / Web / Nginx 分离）
- API 节点横向扩容（同机多副本或多机负载均衡）
- Nginx 多节点动态 upstream 配置
- 云对象存储（S3 / 兼容协议）集成
- 一键升级与滚动重启

---

## 目录

1. [架构概览](#架构概览)
2. [文件说明](#文件说明)
3. [快速开始（单机）](#快速开始单机)
4. [多机部署](#多机部署)
   - [角色分配规划](#角色分配规划)
   - [步骤一：准备配置文件](#步骤一准备配置文件)
   - [步骤二：分发密钥](#步骤二分发密钥)
   - [步骤三：启动基础设施节点](#步骤三启动基础设施节点)
   - [步骤四：启动应用节点](#步骤四启动应用节点)
   - [步骤五：启动 Web + Nginx 节点](#步骤五启动-web--nginx-节点)
5. [API 节点扩容](#api-节点扩容)
   - [同机多副本扩容](#同机多副本扩容)
   - [多机横向扩容](#多机横向扩容)
6. [云与本地混合部署](#云与本地混合部署)
7. [Nginx HTTPS 配置](#nginx-https-配置)
8. [升级操作](#升级操作)
9. [常用运维命令](#常用运维命令)
10. [故障排查](#故障排查)
11. [安全注意事项](#安全注意事项)

---

## 架构概览

```
                       ┌─────────────────────────┐
                       │      负载均衡 / DNS       │
                       └────────────┬────────────┘
                                    │ HTTP/HTTPS
                       ┌────────────▼────────────┐
                       │   Nginx（反向代理入口）   │
                       │   机器 C / 独立节点       │
                       └──────┬──────────┬────────┘
                              │          │
              ┌───────────────▼──┐    ┌──▼────────────────┐
              │  API Server ×N   │    │  Web Frontend      │
              │  Dify API        │    │  Next.js           │
              │  机器 B（可多台）  │    │  机器 C            │
              └───────┬──────────┘    └───────────────────┘
                      │ Celery
              ┌───────▼──────────┐
              │  Worker ×M       │
              │  机器 B 或独立    │
              └───────┬──────────┘
                      │
         ┌────────────▼────────────────────────┐
         │         基础设施节点（机器 A）         │
         │  PostgreSQL │ Redis │ Weaviate       │
         │  Sandbox    │ SSRF Proxy             │
         └────────────────────────────────────-─┘
```

**服务职责说明：**

| 服务 | 职责 | 是否有状态 |
|------|------|------------|
| `db` | PostgreSQL，存储结构化业务数据 | ✅ 有状态，需持久化 |
| `redis` | 任务队列、缓存、Pub/Sub | ✅ 有状态，建议持久化 |
| `weaviate` | 向量数据库，存储文档 embedding | ✅ 有状态，需持久化 |
| `api` | Dify 后端 REST API，无状态 | ❌ 可水平扩容 |
| `worker` | Celery 异步任务处理，无状态 | ❌ 可水平扩容 |
| `web` | Next.js 前端，纯静态渲染 | ❌ 可水平扩容 |
| `nginx` | SSL 终止、路由、负载均衡 | ❌ 可水平扩容 |
| `sandbox` | 隔离代码执行环境 | ❌ 无状态 |
| `ssrf_proxy` | 出站代理，防 SSRF 攻击 | ❌ 无状态 |

---

## 文件说明

```
dify/
├── dify_deploy.sh   # 多角色一键部署脚本（主脚本）
├── deploy.env       # 环境变量示例（复制并填写真实值后使用）
└── README.md        # 本文档
```

脚本运行时会在 `dify/.compose/` 目录下自动生成：

```
dify/.compose/
├── docker-compose.yml   # 按角色动态生成的 compose 文件
└── nginx/
    ├── dify.conf        # nginx 主配置（含 upstream）
    └── dify_proxy.conf  # 通用代理规则（HTTP/HTTPS 共用）
```

---

## 快速开始（单机）

> 适用于开发环境或资源有限的单机生产环境。

### 前置条件

- Docker >= 20.10（含 `compose` plugin 或 `docker-compose` v2）
- 至少 4 GB 可用内存、20 GB 磁盘空间

### 步骤

```bash
# 1. 进入 dify 目录
cd dify/

# 2. 复制并编辑环境变量配置
cp deploy.env deploy.env.local
# 用编辑器打开 deploy.env.local，填写所有 [必填] 项：
#   SECRET_KEY, POSTGRES_PASSWORD, REDIS_PASSWORD,
#   WEAVIATE_API_KEY, SANDBOX_API_KEY

# 3. 生成密钥（示例）
openssl rand -hex 32   # 用于 SECRET_KEY
openssl rand -base64 24  # 用于 POSTGRES_PASSWORD 等

# 4. 一键启动（all-in-one，自动生成 .compose/docker-compose.yml）
bash dify_deploy.sh --env-file deploy.env.local up

# 5. 查看运行状态
bash dify_deploy.sh --env-file deploy.env.local status
```

> **注意**：将 `deploy.env.local`（含真实密钥）加入 `.gitignore`，**不要提交到版本控制**。

启动成功后，浏览器访问 `http://服务器IP` 即可进入 Dify 控制台（默认端口 80）。

---

## 多机部署

### 角色分配规划

以 **三机生产** 为例（可按需合并角色至更少机器）：

| 机器 | 角色 | 推荐配置 |
|------|------|---------|
| 机器 A（192.168.1.10） | `infrastructure` | 8 核 / 16 GB / 200 GB SSD |
| 机器 B（192.168.1.11） | `api,worker` | 8 核 / 16 GB / 50 GB |
| 机器 C（192.168.1.12） | `web,nginx` | 4 核 / 8 GB / 20 GB |

### 步骤一：准备配置文件

在任意机器（建议管理机）上编辑 `deploy.env.local`：

```bash
cp deploy.env deploy.env.local
```

关键修改项（多机时必须指定远程主机地址）：

```bash
# 基础设施节点地址（机器 A 的 IP 或内网 DNS）
POSTGRES_HOST=192.168.1.10
REDIS_HOST=192.168.1.10
WEAVIATE_HOST=192.168.1.10
SANDBOX_HOST=192.168.1.10

# 使用对象存储共享文件（多机必须！否则 API/Worker 各节点文件不互通）
STORAGE_TYPE=s3
S3_ENDPOINT=https://oss-cn-hangzhou.aliyuncs.com
S3_BUCKET_NAME=my-dify-bucket
S3_ACCESS_KEY=your-access-key-id
S3_SECRET_KEY=your-secret-access-key
S3_REGION=cn-hangzhou

# 对外访问地址（nginx 所在机器 C 的域名或 IP）
CONSOLE_WEB_URL=https://dify.example.com
CONSOLE_API_URL=https://dify.example.com
SERVICE_API_URL=https://dify.example.com
APP_WEB_URL=https://dify.example.com
APP_API_URL=https://dify.example.com
```

### 步骤二：分发密钥

将 `deploy.env.local` **安全地** 分发到所有节点（使用 `scp` 或密钥管理工具）：

```bash
# 分发到机器 A
scp deploy.env.local user@192.168.1.10:/opt/dify/

# 分发到机器 B
scp deploy.env.local user@192.168.1.11:/opt/dify/

# 分发到机器 C
scp deploy.env.local user@192.168.1.12:/opt/dify/

# 同步部署脚本
scp dify_deploy.sh user@192.168.1.10:/opt/dify/
scp dify_deploy.sh user@192.168.1.11:/opt/dify/
scp dify_deploy.sh user@192.168.1.12:/opt/dify/
```

> ⚠️ **重要**：`SECRET_KEY`、`POSTGRES_PASSWORD`、`REDIS_PASSWORD` 等密钥在所有节点必须完全一致。

### 步骤三：启动基础设施节点

```bash
# 登录机器 A
ssh user@192.168.1.10
cd /opt/dify

# 启动基础设施服务
bash dify_deploy.sh --role infrastructure --env-file deploy.env.local up

# 等待数据库健康
bash dify_deploy.sh --role infrastructure --env-file deploy.env.local status
```

等待所有服务状态变为 `healthy` 后，再启动应用节点。

### 步骤四：启动应用节点

```bash
# 登录机器 B
ssh user@192.168.1.11
cd /opt/dify

# 启动 API + Worker（可通过 --api-replicas 设置副本数）
bash dify_deploy.sh \
    --role api,worker \
    --api-replicas 2 \
    --env-file deploy.env.local \
    up
```

**首次部署时**，需要等待 API 服务完成数据库初始化（约 1-2 分钟）：

```bash
# 查看初始化日志
bash dify_deploy.sh --env-file deploy.env.local logs
```

看到 `Application startup complete` 日志后，说明 API 初始化完成。

### 步骤五：启动 Web + Nginx 节点

```bash
# 登录机器 C
ssh user@192.168.1.12
cd /opt/dify

# 启动 Web + Nginx，并指定上游 API 节点
bash dify_deploy.sh \
    --role web,nginx \
    --nginx-api-upstreams "192.168.1.11:5001" \
    --env-file deploy.env.local \
    up
```

部署完成后访问 `http://192.168.1.12`（或配置的域名）进入控制台。

---

## API 节点扩容

### 同机多副本扩容

在机器 B 上，通过调整副本数实现单机水平扩展：

```bash
# 扩容至 3 个 API 副本
bash dify_deploy.sh \
    --role api,worker \
    --api-replicas 3 \
    --env-file deploy.env.local \
    up

# 查看运行的副本
docker compose -p dify ps
```

nginx 会通过容器名 `api` 自动发现同机所有 API 副本，**无需手动修改 nginx 配置**。

### 多机横向扩容

增加新的 API 机器（例如 192.168.1.13）：

**1. 在新机器上启动 API + Worker：**

```bash
ssh user@192.168.1.13
cd /opt/dify
bash dify_deploy.sh \
    --role api,worker \
    --env-file deploy.env.local \
    up
```

**2. 更新 Nginx 节点的 upstream，添加新节点：**

```bash
# 登录机器 C，重新生成 nginx 配置
ssh user@192.168.1.12
cd /opt/dify

bash dify_deploy.sh \
    --role web,nginx \
    --nginx-api-upstreams "192.168.1.11:5001 192.168.1.13:5001" \
    --env-file deploy.env.local \
    up

# 热重载 nginx 配置（无需停机）
docker exec $(docker ps -qf name=dify_nginx) nginx -s reload
```

> **注意**：多机共享文件存储时，必须使用对象存储（S3），否则各 API 节点文件目录不互通。

---

## 云与本地混合部署

适合将数据库托管在云服务（RDS / 云 Redis / 云向量库），应用层自建的场景：

```bash
# deploy.env.local 中配置云服务地址
POSTGRES_HOST=rm-xxxx.mysql.rds.aliyuncs.com
POSTGRES_PORT=5432
POSTGRES_USER=dify_prod
POSTGRES_PASSWORD=your-rds-password

REDIS_HOST=r-xxxx.redis.rds.aliyuncs.com
REDIS_PORT=6379
REDIS_PASSWORD=your-redis-password
BROKER_USE_SSL=true   # 云 Redis 通常需要 SSL

# 使用阿里云 OSS 存储文件
STORAGE_TYPE=s3
S3_ENDPOINT=https://oss-cn-hangzhou.aliyuncs.com
S3_BUCKET_NAME=my-dify-bucket
S3_ACCESS_KEY=LTxxxxxx
S3_SECRET_KEY=xxxxxxxx
S3_REGION=cn-hangzhou

# 本机只启动应用层（infrastructure 由云服务承担）
bash dify_deploy.sh \
    --role api,worker,web,nginx \
    --env-file deploy.env.local \
    up
```

---

## Nginx HTTPS 配置

### 使用 Let's Encrypt 证书

```bash
# 安装 certbot（机器 C）
apt-get install -y certbot

# 获取证书（80 端口需可访问）
certbot certonly --standalone -d dify.example.com

# 证书位于 /etc/letsencrypt/live/dify.example.com/
# 创建证书软链接目录
mkdir -p ./ssl
ln -sf /etc/letsencrypt/live/dify.example.com/fullchain.pem ./ssl/fullchain.pem
ln -sf /etc/letsencrypt/live/dify.example.com/privkey.pem   ./ssl/privkey.pem
```

### 修改 nginx 配置启用 HTTPS

编辑 `.compose/nginx/dify.conf`，取消 HTTPS server 块的注释，然后：

```bash
# 热重载 nginx（不停机）
docker exec $(docker ps -qf name=dify_nginx) nginx -s reload
```

### 自动续期

```bash
# 添加 cron 任务每天自动续期
echo "0 2 * * * certbot renew --quiet && docker exec \$(docker ps -qf name=dify_nginx) nginx -s reload" \
    | crontab -
```

---

## 升级操作

### 升级前准备

```bash
# 1. 备份数据库（强烈建议！）
docker exec dify-db-1 pg_dump -U dify dify > dify_backup_$(date +%Y%m%d).sql

# 2. 记录当前版本
grep DIFY_VERSION deploy.env.local
```

### 执行升级

```bash
# 修改 deploy.env.local 中的版本号
sed -i 's/^DIFY_VERSION=.*/DIFY_VERSION=0.16.0/' deploy.env.local

# 在各节点依次执行升级命令
# 顺序：先应用节点 → 再基础设施节点（通常基础设施不需要升级）
bash dify_deploy.sh --env-file deploy.env.local upgrade
```

`upgrade` 命令会自动执行：
1. `docker compose pull` — 拉取新镜像
2. 按顺序重启 `api → worker → web → nginx` 服务

### 数据库迁移

Dify API 启动时会自动执行数据库迁移（Alembic）。升级后查看日志确认迁移成功：

```bash
bash dify_deploy.sh --env-file deploy.env.local logs
# 查找 "Running database migration" 和 "Migration complete" 日志
```

---

## 常用运维命令

```bash
# 查看所有服务状态
bash dify_deploy.sh --env-file deploy.env.local status

# 实时查看全部日志（Ctrl+C 退出）
bash dify_deploy.sh --env-file deploy.env.local logs

# 查看指定服务日志
docker compose -p dify logs -f api

# 重启指定服务
docker compose -p dify restart api

# 进入 API 容器排查问题
docker exec -it $(docker ps -qf name=dify-api) bash

# 数据库备份
docker exec dify-db-1 pg_dump -U ${POSTGRES_USER} ${POSTGRES_DB} \
    > backup_$(date +%Y%m%d_%H%M%S).sql

# 数据库恢复
docker exec -i dify-db-1 psql -U ${POSTGRES_USER} ${POSTGRES_DB} \
    < backup_20240101_120000.sql

# 停止所有服务（保留数据卷）
bash dify_deploy.sh --env-file deploy.env.local down

# 停止并清理数据卷（⚠️ 不可逆，会删除所有数据）
docker compose -p dify down -v
```

---

## 故障排查

### API 服务无法连接数据库

```bash
# 检查 postgres 容器健康状态
docker compose -p dify ps db

# 测试数据库连接
docker exec dify-db-1 pg_isready -U dify

# 查看数据库日志
docker compose -p dify logs db
```

### Weaviate 启动失败

```bash
# 常见原因：数据目录权限问题
docker compose -p dify logs weaviate

# 重置 weaviate 数据（⚠️ 会清空向量数据，需重新索引所有文档）
docker compose -p dify stop weaviate
docker volume rm dify_dify_weaviate_data
docker compose -p dify up -d weaviate
```

### API 健康检查失败

```bash
# 手动检查 API 健康端点
curl -f http://localhost:5001/health

# 查看 API 详细启动日志
docker compose -p dify logs --tail=200 api
```

### nginx 502 Bad Gateway

```bash
# 检查 upstream 服务是否正常
docker compose -p dify ps api web

# 验证 nginx 配置语法
docker exec $(docker ps -qf name=dify_nginx) nginx -t

# 查看 nginx 错误日志
tail -100 ./logs/nginx/error.log
```

---

## 安全注意事项

1. **密钥管理**
   - `SECRET_KEY` 首次设置后**永不更改**，否则所有加密数据（API Key、密码等）将失效。
   - 建议使用密钥管理服务（HashiCorp Vault / 云 KMS）存储和注入密钥，避免明文存储。
   - `deploy.env.local` 文件应设置 `chmod 600`，并加入 `.gitignore`。

2. **网络隔离**
   - 基础设施服务（PostgreSQL / Redis / Weaviate）不应直接暴露到公网。
   - 建议在云环境使用安全组/防火墙规则，仅允许应用节点访问数据库端口。
   - API 服务的 5001 端口建议绑定到内网 IP，通过 nginx 统一对外提供服务。

3. **HTTPS**
   - 生产环境必须启用 HTTPS，禁止明文 HTTP 传输用户数据和 API 密钥。
   - 使用 TLS 1.2+ 和强密码套件。

4. **访问控制**
   - 首次部署后立即在控制台创建管理员账号，并关闭注册（Settings → Authentication）。
   - 定期轮换 Redis 密码、Weaviate API Key（API Key 可单独在 Dify 控制台轮换，不影响 SECRET_KEY）。

5. **备份策略**
   - PostgreSQL：建议每日全量备份 + WAL 日志归档，保留至少 7 天。
   - Weaviate：定期导出向量数据（或通过 Dify 重新索引文档作为恢复手段）。
   - 文件存储：如使用对象存储，开启版本控制和跨区域复制。

6. **Sandbox 安全**
   - 生产环境 `SANDBOX_ENABLE_NETWORK=false`，防止代码执行逃逸到公网。
   - `ssrf_proxy` 容器限制了 Dify 内部服务对外的 HTTP 请求目标，避免 SSRF 攻击。
