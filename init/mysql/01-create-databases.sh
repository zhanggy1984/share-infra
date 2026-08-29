#!/usr/bin/env bash
# ============================================================
# 共享 MySQL 初始化：只建库 + 账号 + 授权，不含任何业务表
# 表结构由各 agent 应用启动时自建（create_all / alembic / init.sql 应用侧执行）
#
# 密码一律从容器环境变量读取（由 docker-compose 从 infra/.env 注入），
# 本仓库不硬编码任何凭据 —— clone 后仅需 cp .env.example .env 并填写即可。
#
# 库/账号对齐各 agent 现状；每个账号仅授权自己的库。
# 注意：本文件只在 mysql 数据卷首次创建时执行一次（docker-entrypoint-initdb.d）。
# 若因数据卷已存在而未生效，需删卷重建（生产环境谨慎操作）。
#
# 密码字符集限制：仅限字母/数字/下划线（避免 SQL 字面量转义）。
# ============================================================
set -euo pipefail

# 密码经 MYSQL_PWD 环境变量传入（不落命令行：避免 ps 泄露进程参数、避免凭据扫描误报）
export MYSQL_PWD="${MYSQL_ROOT_PASSWORD}"
mysql --user=root <<SQL
-- ---------- 建 5 个 agent 库 ----------
CREATE DATABASE IF NOT EXISTS contract_check
    DEFAULT CHARACTER SET utf8mb4 DEFAULT COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS native_rag
    DEFAULT CHARACTER SET utf8mb4 DEFAULT COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS customer_service
    DEFAULT CHARACTER SET utf8mb4 DEFAULT COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS ai_evaluation
    DEFAULT CHARACTER SET utf8mb4 DEFAULT COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS smart_procurement
    DEFAULT CHARACTER SET utf8mb4 DEFAULT COLLATE utf8mb4_unicode_ci;

-- ---------- contract-check：contract ----------
CREATE USER IF NOT EXISTS '${MYSQL_CONTRACT_USER}'@'%' IDENTIFIED BY '${MYSQL_CONTRACT_PASSWORD}';
GRANT ALL PRIVILEGES ON contract_check.* TO '${MYSQL_CONTRACT_USER}'@'%';

-- ---------- good-question：native_rag_user ----------
CREATE USER IF NOT EXISTS '${MYSQL_RAG_USER}'@'%' IDENTIFIED BY '${MYSQL_RAG_PASSWORD}';
GRANT ALL PRIVILEGES ON native_rag.* TO '${MYSQL_RAG_USER}'@'%';

-- ---------- customer-service：csuser ----------
CREATE USER IF NOT EXISTS '${MYSQL_CS_USER}'@'%' IDENTIFIED BY '${MYSQL_CS_PASSWORD}';
GRANT ALL PRIVILEGES ON customer_service.* TO '${MYSQL_CS_USER}'@'%';

-- ---------- agent-evaluation-offline：evaluation（运行时 DML）+ evaluation_migrate（迁移 DDL） ----------
-- P2-C3 最小权限分离：运行时账号只 DML（SELECT/INSERT/UPDATE/DELETE，无 DDL）；
-- DDL 由迁移专用账号持有（仅 alembic upgrade head 短时使用）。
-- 只动 ai_evaluation 段，其余 agent 账号/库不受影响。
-- 存量库（老脚本已授 ALL 给 evaluation）：init 脚本只首跑，需在共享 MySQL 手动降权，
-- 见 agent-evaluation-offline 上线待办 P2-C3 注记的存量 SQL。
CREATE USER IF NOT EXISTS '${MYSQL_EVAL_USER}'@'%' IDENTIFIED BY '${MYSQL_EVAL_PASSWORD}';
-- 运行时账号：最小 DML（无 DDL）
GRANT SELECT, INSERT, UPDATE, DELETE ON ai_evaluation.* TO '${MYSQL_EVAL_USER}'@'%';
CREATE USER IF NOT EXISTS '${MYSQL_EVAL_MIGRATE_USER}'@'%' IDENTIFIED BY '${MYSQL_EVAL_MIGRATE_PASSWORD}';
-- 迁移账号：单库 ALL（DDL+DML，含 alembic_version 读写），无 GRANT OPTION
GRANT ALL PRIVILEGES ON ai_evaluation.* TO '${MYSQL_EVAL_MIGRATE_USER}'@'%';

-- ---------- smart-procurement：smart ----------
CREATE USER IF NOT EXISTS '${MYSQL_SP_USER}'@'%' IDENTIFIED BY '${MYSQL_SP_PASSWORD}';
GRANT ALL PRIVILEGES ON smart_procurement.* TO '${MYSQL_SP_USER}'@'%';

FLUSH PRIVILEGES;
SQL
unset MYSQL_PWD
