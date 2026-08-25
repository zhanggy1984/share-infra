# 共享中间件 infra（shared-infra）

> **5 个 agent（contract-check / good-question / customer-service / agent-evaluation-offline / smart-procurement）共用的一套中间件**。
> 每个 agent 不再自带 MySQL / Redis / Milvus / Neo4j / MinIO / BGE-M3，统一由本仓库提供；
> agent 的 `docker-compose.yml` 只声明 `external: true` 的 `shared-infra` 网络（网络别名即逻辑主机名）+ 应用服务，无任何中间件定义。

---

## 一、包含哪些中间件

| 服务 | 逻辑主机名 | 版本 | 说明 |
|---|---|---|---|
| MySQL | `mysql` | mysql:8.0 | 5 个 agent 各自独立 database + 独立账号 |
| Redis | `redis` | redis:7-alpine | 5 个 agent 按 db index 隔离 |
| Milvus | `milvus` | milvusdb/milvus:v2.5.4 | 向量库，collection 前缀隔离 |
| etcd | `etcd` | quay.io/coreos/etcd:v3.5.14 | Milvus 伴生元数据 |
| MinIO | `minio` | minio/minio | Milvus 对象存储 + agent 标书/文件 bucket |
| Neo4j | `neo4j` | neo4j:5 | 图谱库（sp 唯一用户） |
| Attu | `attu` | zilliz/attu:v2.5.6 | Milvus 可视化管理 UI |
| BGE-M3 | `bge-m3` | 自构建（./docker/bge-m3） | embedding 服务，模型懒加载 |

> 应用容器内永远用**逻辑主机名**连接（如 `mysql:3306`、`milvus:19530`）；宿主端口仅用于本机调试工具。

---

## 二、快速开始

### 前置

- Docker Desktop（Linux 容器）、`docker compose` v2.20+。
- 首次启动 BGE-M3 需联网下载模型（`hf-mirror.com` 镜像，已配置），模型缓存于 `bge-m3-model` 卷，后续离线加载。

### 启动

```bash
cp .env.example .env     # 首次：生成环境变量文件（所有密码占位为 CHANGE_ME，务必填写）
# 编辑 .env：设置 MySQL root 与 5 个 agent 库账号密码、Neo4j、MinIO 密码
docker compose up -d --build
docker compose ps        # 全部 Up + healthy
```

> 安全约定：所有密码只写在 `.env`（已被 `.gitignore` 排除，**不提交**）。
> MySQL 库/账号由 `init/mysql/01-create-databases.sh` 在首次建卷时创建，
> 密码经 compose 从 `.env` 注入容器 —— 本仓库不保存任何真实或默认凭据。

### 调试工具连接（宿主端口）

| 服务 | 地址 |
|---|---|
| MySQL | `localhost:33061` |
| Redis | `localhost:36379` |
| Milvus | `localhost:39530` |
| Neo4j HTTP / Bolt | `localhost:37474` / `localhost:37687` |
| MinIO API / Console | `localhost:39000` / `localhost:39001` |
| Attu（Milvus UI） | `http://localhost:38000` |
| BGE-M3 | `http://localhost:38081`（`/health`，`/embed`） |

---

## 三、数据隔离约定

| 中间件 | 隔离维度 | 约定 |
|---|---|---|
| MySQL | database + account | 每个 agent 独立库 + 独立账号，仅授权自己的库（见 `init/mysql/`） |
| Redis | db index | sp=`/0`、cs=`/1`、gq=`/2` |
| Milvus | collection 前缀 | `sp_` / `cs_` / `rag_` |
| MinIO | bucket | 业务文件各自 bucket（如 sp 的 `bid-files`）；Milvus 用 `a-bucket` |
| Neo4j | — | 共享一个实例，sp 为唯一图谱用户 |
| BGE-M3 | — | 共享 embedding 服务，任何 agent 可 `http://bge-m3:8081/embed` |

---

## 四、agent 接入方式

每个 agent 的 `docker-compose.yml` 结尾声明外部共享网络，应用容器加入后即可用逻辑主机名直连：

```yaml
networks:
  shared-infra:
    external: true
    name: shared-infra_shared-infra
```

各 agent 的部署方式见对应仓库 README（先部署本 infra，再起 agent）。

---

## 五、维护

- 端口、密码等可调项集中在 `infra/.env`（参照 `.env.example`）。
- 中间件数据全部持久化在命名卷：`mysql-data` / `redis-data` / `neo4j-data` / `etcd-data` / `minio-data` / `milvus-data` / `bge-m3-model`。
