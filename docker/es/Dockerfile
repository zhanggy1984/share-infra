# ============================================================
# 共享 Elasticsearch 8.13.4（agent-evaluation-online 观测存储）
#
# 在官方镜像基础上预装 analysis-ik 中文分词插件：
# - online 事件索引映射要求 text 字段 IK 分词（detail §2.1 / task.md T-1.3/S-5）
# - 插件构建期联网拉取（get.infini.cloud），一次入镜像长期复用（同 bge-m3 模型卷思路）
#
# 版本锚点：ES 8.13.4 ⇄ analysis-ik 8.13.4（须与 ES 小版本严格一致）
# ============================================================

FROM docker.elastic.co/elasticsearch/elasticsearch:8.13.4

# 插件 zip 经 curl 落盘后 file:// 安装，避免 elasticsearch-plugin 半装状态；失败可见根因
RUN set -eux; \
    curl -fsSL -o /tmp/analysis-ik.zip \
      "https://get.infini.cloud/elasticsearch/analysis-ik/8.13.4"; \
    elasticsearch-plugin install --batch file:///tmp/analysis-ik.zip; \
    rm -f /tmp/analysis-ik.zip
