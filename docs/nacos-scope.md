Nacos 引入范围 Design Doc
==========================

Context and motivation
----------------------

计划在 share-infra 引入 Nacos 作为配置中心，服务两个用途：

1. **Prompt 版本化 + 热更新** —— 各 agent 的 LLM 提示词目前全部硬编码在 `.py` 源码里，改一个字就要重建镜像、重启容器。
2. **参数配置化** —— 各项目的运行时参数收敛到一处，取代分散的页面配置、MySQL KV 表与 `.env`。

触发原因：现状是**五套互不相同的配置实现**——offline / online / sp 三家各自造了一套「MySQL KV + 进程内缓存」（表名分别是 `system_config` / `dict_config` / `system_config`，缓存 TTL 与审计能力各不相同），cs / cc / gq 三家的参数则散落在 `.env` 与硬编码常量里。改一个共同参数要在六个仓库里用六种方式改。

**本文档只定义「范围」**（哪些东西上、哪些明确不上、为什么），不含技术方案。技术方案开工前另出文档。

Goals:
- 冻结每一家的迁入清单与**排除清单**，使后续改造不再反复讨论边界
- 记录每一项「不上」的判断依据，防止后人只看结论、重新提议把它们加回来
- 明确改造前必须具备的共同基座

Non-goals for first implementation (v1):
- 不在本期做技术方案（组件形态、命名规范、客户端封装、批次切分）
- 不迁任何**凭据**（详见「`.env` 边界」）
- 不迁**评测基准数据**（offline 的 `judge_rubric`）
- 不迁**跟实体走**的参数（gq 的 per-document 切分参数、sp 的 per-project `scoring_rubric`）
- 不做配置的灰度/回滚策略设计（Nacos 原生能力够用，细节留技术方案）

Implementation considerations
-----------------------------

### 技术栈实测（与直觉不符，先纠正）

六个项目**全部是 Python / FastAPI 后端 + Vue 前端**，LLM 统一走 DeepSeek（OpenAI 兼容协议），启动期配置统一用 `pydantic-settings` 的 `BaseSettings` + `.env`。

**没有 Java、没有 Spring、没有 Spring Cloud。** 因此接入方式是 `nacos-sdk-python`，不是 Spring Cloud Alibaba。

- 版本 **3.2.0**（2026-04-27 发布），要求 Python ≥ 3.10，活跃维护、无已知漏洞
- **必须避开 2.0.0 – 2.0.6**：该区间版本重连后不自动重新订阅配置，会导致配置静默不恢复

### Nacos 客观约束（已查实）

| 约束 | 值 | 影响 |
|---|---|---|
| 单配置内容上限 | 默认 100KB | 长 system prompt 需先量体积；超限需拆分 |
| 版本历史保留 | 30 天 | **不能当业务审计用**，需要审计的场景得自己补 |
| 回滚 | 仅「更新」类型可回滚（首建不可） | 首次发布的坏配置只能手工改回 |
| 灰度发布 | 按**实例 IP**，非流量比例 | 多实例灰度够用，按用户/租户灰度做不到 |

### 已定模式：prompt 整段外置 + 读侧契约校验

**决策**：prompt **整段外置**，不拆「骨架 + 文案槽位」。安全护栏随整段一起上。

**配套（不可省）**：**读侧契约校验**。每份 prompt 配一份「必含标签 / 占位符」清单，应用在**启动加载与收到推送时**校验；不合格则**拒绝加载、保留上一版**，并打 error 日志。

校验放在读侧而非写侧，原因是将来会有人在 Nacos 控制台直接改配置，**写侧校验拦不住控制台**。

**为什么必须配校验**：各项目的 prompt 与其解析器成对存在，且失败是**静默的**——

- `smart-procurement/app/services/review_service.py:387` 注释原文：「无标签降级全文当 answer，契约不破」
- `customer-service/backend/app/agent/intent.py:50`：JSON 解析失败 → `IntentResult(intent="CHITCHAT", ..., summary="意图分类失败，兜底为闲聊")`

即 prompt 改坏不会报错，只会让评分悄悄变烂、让所有问题被当成闲聊。**对一个评测类系统，这比直接崩溃更危险。**

### `.env` 边界（两刀切）

**第一刀（不可协商）：凭据永远留 `.env`。**

1. Nacos 开源版控制台无细粒度 RBAC、鉴权默认弱。凭据进 Nacos = 把「文件系统权限边界」换成「Nacos 控制台边界」，**后者更弱**；且与既有的「凭据不落公开仓库、部署时注入」原则冲突。
2. **鸡生蛋**：Nacos 自己也需要凭据（连它的 MySQL 库、控制台账号），这些必须留 `.env`。因此 `.env` 机制**不可能被消灭**。
3. 真要集中管凭据，正解是 Vault / K8s Secret / SOPS 这类**密钥管理系统**，不是配置中心。

**第二刀（性质）：`.env` 管「进程怎么起来」，Nacos 管「业务怎么跑」。**

判据：**这个值描述的是「部署形态」还是「业务策略」？**

- **部署形态**（连接串、拓扑、端口、连接池大小、运行环境）→ 留 `.env`。理由：这些值**必须与容器定义一致**，放 Nacos 会造成「进程实际连的库」与 compose 里写的不一致，排查时看不见。
- **业务策略**（限流、超时、TTL、轮数、模型名、阈值）→ 上 Nacos。理由：运行时可调，且调了就想立刻生效。

**反直觉结论**：引入 Nacos 后 `.env` **只会变大**（新增 Nacos 地址、namespace、鉴权、降级开关），只有业务策略那一栏会挪走。真正被解决的痛点是「**改配置必须重启容器**」，不是「配置文件太多」。

### 安全前提：SSRF 白名单

**七家里只有 offline 有 LLM 端点白名单**（`llm_allowlist`、`base_url_allowlist`）。

cs / cc / gq 三家**零防护**，而本次决定把 `DEEPSEEK_BASE_URL` 纳入可热改范围——**等于开了一个 SSRF 口子**：能改配置的人可以让这些服务的 LLM 客户端去请求任意地址（内网服务、云 metadata 端点）。

> **结论：host 白名单是本次改造的前置条件，不是可选项。** 改造 cs / cc / gq 任一家之前，必须先把白名单建起来。

High-level behavior
-------------------

改造完成后，一次配置变更的生命周期：

1. 变更方在 Nacos 控制台（或经页面代理）修改某项目的 prompt 或参数
2. 应用通过 SDK 的长轮询监听收到推送
3. **读侧契约校验**：按该配置项的清单检查必含标签 / 占位符 / 取值范围
   - 通过 → 更新进程内缓存，**立即对新请求生效**
   - 不通过 → **丢弃本次变更、保留上一版**，打 error 日志（含配置项名与缺失项）
4. 应用按新配置处理后续请求

**启动路径**：应用启动时从 Nacos 拉取配置 → 校验 → 缓存。**Nacos 不可达时，回退到本地快照**（Nacos 客户端自带的本地快照机制），不阻塞启动；启动期拉取失败打 warn 日志。

**范围定义**
------------

以下为逐项目冻结清单。「不上」列同时给出理由。

### smart-procurement（sp）

| 类别 | 内容 |
|---|---|
| **Prompt 上** | **已完成外置（2026-09-21）**：10 个模板落在 `app/prompts/*.md`，代码侧由 `app/prompts/__init__.py` 的 `load_prompt(name)` 读取。清单：`score_system`（评分五段式 system）、`chat_system`（对话五段式 system）、`tools_declaration`（工具可用声明）、`override_context` / `retrieval_unavailable_hint` / `not_found_answer` / `unknown_answer`（`app/ai/agent/agent_loop.py:68,73,79,84` 四个模块级常量）、`fraud_report_system`（`services/fraud_detection_service.py:507`）、`tag_match_system`（`services/tag_translation_service.py:59`）、`conversation_summary_system`（`services/conversation_service.py:189`） |
| **配置上** | `llm.temperature`、`llm.max_tokens`、`fraud.auto_pass_threshold`、`fraud.critical_threshold`、`fraud.weight_text`、`fraud.weight_graph`、`fraud.weight_price`、`fraud.similar_pair_threshold`、`fraud.text_similarity_threshold`（共 9 键） |
| **先删不迁** | `conflict.employment_years`、`review.deviation_threshold`——`config_service.py:29` 的 `_DEFAULTS` 自身标注「业务逻辑未实现，当前未接入，仅可配置存储」 |
| **不上** | `_INJECTION_PATTERNS`（正则，属代码）；`_INJECTION_GUARD_PREFIX`（**原写「正则，属代码」有误，2026-09-21 复核更正**：它是 41 字符**纯文案**、非正则，本文件唯一的正则是 `_INJECTION_PATTERNS`。复核后仍决定留代码，但理由不是「它是正则」）；`_FAITHFULNESS_GUARD` / `_INJECTION_GUARD` / `_NO_SYSTEM_PROMPT_DISCLOSURE`（被 `_score_system` 与 `build_chat_prompt` **共用**，留代码单副本——展开进模板等于同段安全文案存两份，改一份忘一份即注入防御静默失效）；`_retrieval_meta_block`（是渲染逻辑，不是文案）；`scoring_rubric`（per-project 字段，已在维度表，维持现状） |

**契约校验清单**：评分 prompt 必含 `<thinking>` / `</thinking>` / `<answer>` / `</answer>` / `<bid_content>` / `<role>` / `<output>`；护栏关键词必须存在。评分 prompt 的 `{dimension_name}` / `{max_score}` / `{rubric}` 以占位符保留，应用侧 format。

**⚠️ 与「整段外置」的口径偏差（2026-09-21 实测确认，非设想）**：sp 外置后的模板**不是**纯文本整段，含占位符——
`score_system`：`{dimension_name}` / `{max_score}` / `{rubric}` / `{injection_guard}` / `{no_system_prompt_disclosure}`；
`chat_system`：`{role_context}` / `{tools_declaration}` / `{faithfulness_guard}` / `{injection_guard}` / `{no_system_prompt_disclosure}`；
`override_context`：`{context}`。
成因有二：① `tools_declared` 是**布尔开关**，控制 `_TOOLS_DECLARATION` 段拼不拼进去，单一文本模板表达不了「这段可有可无」；② 三个 guard 被两个 builder 共用，展开进模板即同段安全文案存两份副本。
**后果（改造时必须正视）**：Nacos 侧覆盖模板**改不动** guard 与这些槽位的注入来源——guard 文案要改仍须发版。若接受不了这个限制，就得改回把 guard 整段外置并接受双副本，或把 guard 也拆成独立模板（覆盖粒度随之从「整段」退化为「片段」）。

**⚠️ 降级链的缺口（同上，实测确认）**：`load_prompt` 是**导入期**读文件。`app/prompts/*.md` 缺失或损坏 → `FileNotFoundError` → **应用启动即失败**，不存在下文「降级路径」里写的「代码内置默认值」这一层（那一层说的是 `system_config` 配置项，**对 prompt 不成立**）。改造时须明确取舍：就让它在导入期崩（fail-fast，改动最小），还是补一层内置兜底。截至目前**未做兜底，也无任何测试覆盖这个失败模式**。

**⚠️ 待验证观测**：`deepseek_client.py:173/266/373` 三处确实读取了 `llm.temperature` / `llm.max_tokens`，但 `agent_loop.py:153/188` 又显式传了 `max_tokens=2048`。**显式传参可能覆盖配置项**，导致这两个键在对话链路上不生效。改造时须先验证。

### customer-service（cs）

| 类别 | 内容 |
|---|---|
| **Prompt 上** | `build_intent_system()`（`app/agent/prompts/intent.py:11`）、严重性评估 system（`state_machine/complaint_flow.py:66`）、`DECISION_PROMPT`（`agent_loop.py:29`）、orchestrator 四处（`orchestrator.py:253` 检索故障兜底 / `:353` 政策作答 / `:431` `:436` 闲聊 2 变体）、`INJECTION_GUARD_PREFIX`（`app/agent/prompts/guard.py:31`） |
| **规则话术上** | 7 处不经 LLM、原样返回给用户的话术：`orchestrator.py:209`、`:211`、`:214`、`:220`、`:347`、`:429`，以及 `:228 _EMPTY_ANSWER_FALLBACK` |
| **配置上** | `.env` 策略键：`DEEPSEEK_PER_KEY_RPM`、`DEEPSEEK_QUEUE_MAX_SIZE`、`DEEPSEEK_QUEUE_TIMEOUT`、`DEEPSEEK_TIMEOUT_CHAT`、`DEEPSEEK_TIMEOUT_REASONER`、`CONVERSATION_MAX_ROUNDS`、`SESSION_TTL`、`RAG_CACHE_TTL`、`INTENT_CACHE_TTL`、`JWT_EXPIRE_HOURS` |
| **高风险键** | `DEEPSEEK_MODEL_CHAT`、`DEEPSEEK_MODEL_REASONER`、`DEEPSEEK_BASE_URL`（改错 = 全量故障；`BASE_URL` 必须配 host 白名单） |
| **新增为可配** | `temperature=0.1`（`agent_loop.py:186`、`intent.py:89`）、`TOP_K=10`（`rag/retriever.py:21`） |
| **不上** | 凭据 5 个（`DEEPSEEK_API_KEYS`/`JWT_SECRET_KEY`/`ADMIN_DEFAULT_PASSWORD`/`MYSQL_URL`/`REDIS_URL`）；部署形态 6 个（`VECTOR_STORE`/`SERVICE_MODE`/`APP_ENV`/`MILVUS_URI`/`MYSQL_POOL_SIZE`/`MILVUS_COLLECTION`）；`INJECTION_RE`（正则） |

**契约校验清单**：intent prompt 必含 JSON 关键词与 `VALID_INTENTS` 各枚举值；严重性 prompt 必含 `severity` 与 `HIGH`/`MEDIUM`/`LOW`；`DECISION_PROMPT` 必含 `{tools}` 占位符与三个工具名（`search_policy`/`query_order`/`list_user_orders`）；政策作答 prompt 必含 `<document>`。

**⚠️ 跨项目约束**：上述 7 处规则话术参与**评测一致性校验**。`orchestrator.py:111-113` 注释原文：「token 拼接『部分流 + 兜底』≠ done.content『兜底』，触发评测校验失败」。**改这些话术必须与 agent-evaluation-offline 侧的断言对齐后一起改**，否则故障会在评测端暴露，排查路径跨项目。

### contract-check（cc）

| 类别 | 内容 |
|---|---|
| **Prompt 上** | `extractor.py:35` SYSTEM_PROMPT、`validation/semantic_evaluator.py:25` SYSTEM_PROMPT、`graph/decisions.py:28` OCR_SYSTEM_PROMPT、`graph/decisions.py:41` EXTRACT_SYSTEM_PROMPT |
| **配置上** | `llm_timeout`、`llm_max_retries`、`task_timeout_seconds`、`max_concurrent_tasks`、`max_upload_mb`、**决策引擎开关群**（`tool_decision_enabled`、`ocr_decision_enabled`、`ocr_decision_allow_llm_skip`、`extract_decision_allow_llm_retry`、`tool_decision_max_rounds`、`tool_decision_max_tokens`、`tool_decision_timeout`） |
| **高风险键** | `deepseek_model`、`deepseek_base_url`（需 host 白名单） |
| **新增为可配** | `temperature=0.1`（`llm/llm_client.py:38`、`llm/tool_client.py:49`）、`max_tokens=MAX_TOKENS` 常量（`llm/llm_client.py:37`，值为 8192） |
| **不上** | 规则页的 `expression` 字段（是**业务内容**，已被规则页 + 本体版本管理，不是运行时配置）；`rules/manual/*.json` |
| **顺带修** | `backend/.env.example` 仅 8 键，而 `Settings` 有约 40 字段，**严重不同步**，建议本次一并补齐 |

**契约校验清单**：抽取 / 语义审查 prompt 输出经 `call_json` 解析，必含其 JSON 字段名；决策 prompt 输出 tool calls，必含工具名 `decide_ocr` / `decide_extract_retry`。

**决策引擎开关群是本项目最有价值的迁入项**：决策引擎行为异常时可立刻关闭，现在只能发版。

### good-question（gq）

| 类别 | 内容 |
|---|---|
| **Prompt 上** | `services/chat_service.py:43` SYSTEM_PROMPT、`:123 _OVERRIDE_CONTEXT_PROMPT`、`:134 _RETRIEVAL_UNAVAILABLE_HINT`（三处正文均已外置至 `backend/prompts/*.md`）。原列的 `services/llm_service.py:36 REWRITE_PROMPT` **已删除**（2026-09-21，无任何调用方的死代码），不再需要迁移 |
| **配置上** | `similarity_threshold_low`(0.20)、`rerank_low_confidence_threshold`(0.50)（**本项目配置面的核心价值**）、`chat_llm_max_attempts`、`chat_llm_retry_backoff_seconds`、`chat_cache_ttl_seconds`、`chat_retention_days`、`chat_cleanup_interval_seconds`、`chat_cleanup_batch_size`、`login_fail_max`、`login_fail_window_seconds`、`jwt_expire_minutes`、`max_upload_size_mb`、`deepseek_model`、`deepseek_base_url` |
| **新增为可配** | `temperature=0.3`（`services/llm_service.py:30`）、`top_k=6 if summary else 3`（`services/retrieval_service.py:236`，注意是条件表达式，需拆为两个键或保留分支逻辑） |
| **不上（重要）** | **`EMBEDDING_MODEL_NAME`、`RERANK_MODEL_NAME`** 以及 `EMBEDDING_DEVICE`、`RERANK_DEVICE`、`HF_ENDPOINT` → 留 `.env` |
| **不上** | per-document 切分参数（`chunk_size`/`overlap_token`，跟着文档走，不是全局配置） |

**为什么 embedding / rerank 模型名必须排除**：`EMBEDDING_MODEL_NAME`（`jinaai/jina-embeddings-v2-base-zh`）与 `RERANK_MODEL_NAME`（`BAAI/bge-reranker-v2-m3`）是**本地模型**。换一个 embedding 模型，向量空间即改变，**已有 Milvus 索引全部失效**，必须重建全量向量。热更的后果是：用新模型编码 query、去检索旧模型建的索引，**检索结果静默错乱且不报错**。

> 这与「模型名也收进 Nacos」的决策**不冲突**：`DEEPSEEK_MODEL` 是远程 API 的模型名，切换无副作用；`EMBEDDING_MODEL_NAME` 是本地模型，切换有数据迁移代价。**两者性质不同，不可类推。**

**契约校验清单**：SYSTEM_PROMPT 必含 `{summary}` 占位符；override_context 必含 `{context}`。（原列 REWRITE_PROMPT 必含 `{question}` 一项，随该 prompt 删除一并移除）

### agent-evaluation-online（online）

| 类别 | 内容 |
|---|---|
| **Prompt** | 无（该平台不调用 LLM，`analyzer/classify.py:40` 的 `llm_*` 是错误类型白名单，不是 prompt） |
| **配置上** | `claim_ttl_days`、`auto_fixed_k_default`、`auto_requeue_max_default`、`rollup_late_k_h`、`keyword_search_days`、`metric_agg_cache_ttl_s`、`metric_agg_timeout_ms`、`trace_query_timeout_ms`、`trace_judge_purge_days`（9 个全局键）+ per-agent 键 `fallback_utterance`、`timeout_ms` |
| **先删不迁** | 5 个**零读取点的僵尸键**，`frontend/src/configLabels.ts` 自身标注 `live: false`（含 `cluster_window_days`、`llm_call_observe_window_min` 等） |

### agent-evaluation-offline（offline）

| 类别 | 内容 |
|---|---|
| **Prompt** | **不上**（`judge_rubric` 是评测资产，见下） |
| **配置上** | **仅 7 键**——`scope=global` 且 `is_hot=true` 的全部：`retain_runs`、`max_active_runs_per_agent`、`judge_llm.base_url`、`judge_llm.model_name`、`judge_cache_enabled`、`judge_cache_ttl_seconds`、`llm_allowlist` |
| **不上** | `scope=run` 的 14 键（`global_max_inflight`、`per_agent_concurrency`、`case_timeout`、`scoring_timeout`、`run_timeout`、`perf_repeat_count`、`judge_concurrency`、`judge_call_timeout`、`judge_na_threshold`、`judge_max_retries`、`judge_repeat`、`breaker_failure_threshold`、`breaker_open_duration`、`max_retries`） |
| **不上** | `heartbeat_interval`（`is_hot=false`）、`scope=registration` 的 `file_max_size` 与 `base_url_allowlist` |
| **不上** | `judge_rubric` 表 |

**为什么 `scope=run` 的 14 键不上**：这些键在创建 run 时**快照冻结**（`api/runs.py:86` `_snapshot_run_config`，注释「创建时冻结，执行期不再读热配置」），语义就是「冻结可复现」。把它们变成热更会破坏评测结果的可重现性。

**为什么 `judge_rubric` 不上**：它是**评测基准资产**，不是运行时配置。`rubric_version` 被写进每条 verdict，并作为 judge 缓存键的一部分（`judge/verdict_cache.py:98`），最终被 scorer 读取（`runner/scorer.py:549`）。它的语义是「冻结可复现」——评测跑完必须能说清当时用的是哪个版本的裁判标准。这与 Nacos「当前值 + 推送」的模型**直接冲突**。

**为什么 `base_url_allowlist` 不上**：它是**安全白名单**。可热改的白名单等于可开后门。该仓自己把它标为 `is_hot=false`，已表达同一判断。

**Judge LLM 的 base_url / model_name 反而是要上的**——它们本就已是运行时配置，这是高风险的「模型名 + BASE_URL 可热改」在项目内的现成先例。

参照物：以 offline 为目标形态
------------------------------

**技术方案阶段以 agent-evaluation-offline 为参照物，而不是以 smart-procurement 为参照物。**

选 sp 当首个改造对象是对的（它的 prompt 集中在单个文件、改造面最脏，能压出**改造成本上限**），但它的**目标形态**不具备参考价值——sp 需要新造 `is_hot`、新造类型系统、新造白名单。

offline 则已经把本次要解决的多数问题**想过一遍并用代码表达了判断**，应作为**目标形态**的参照：

| offline 已有的机制 | 位置 | 对本次改造的意义 |
|---|---|---|
| **`is_hot` 字段**（区分「能热更」与「要重启」） | `seed.py` `DEFAULT_SYSTEM_CONFIG` | 其他五家都没有这个概念，**它就是「哪些该热更」的现成答案** |
| **`scope` 字段**（run / global / registration） | 同上 | 「哪些必须冻结」的现成答案 |
| **运行时 LLM 端点配置** | `judge_llm.base_url`、`judge_llm.model_name`，均 `is_hot=true` | 「模型名 + BASE_URL 可热改」已在此落地 |
| **LLM 端点白名单** | `llm_allowlist`（global）、`base_url_allowlist`（registration，`is_hot=false`） | cs/cc/gq 要从零建的 SSRF 防护，此处有可抄的实现与**「白名单不该热改」的既有判断** |
| **类型与取值约束元数据** | 每键带 `meta: {type, min, max, max_len, nullable}` | 读侧校验的取值部分可复用同一思路 |
| **本地缓存 + TTL + 失效** | online 的 `dict_config.py:38-58`（60s TTL）+ `invalidate_cache()` | Nacos 客户端封装可参照 |

**具体参照什么**：技术方案定义「哪些配置项需要 `is_hot` 语义」「哪些需要 `scope` 语义」「白名单如何实现」「类型与取值校验如何表达」时，**一律先看 offline 怎么做的，能抄就抄，不重新发明**。

Error handling and UX
---------------------

配置错误分三类，处理方式不同：

**1. 契约校验失败（prompt 不含必需标签 / 占位符）**
- 丢弃本次变更，保留上一版生效值
- 打 **error** 日志，内容含：配置项名、缺失的标签清单、变更来源
- **不中断服务**：继续用旧值跑，宁可跑旧 prompt 也不跑坏 prompt

**2. 取值校验失败（数值越界、模型名不在白名单、base_url host 不在白名单）**
- 同上：丢弃变更、保留旧值、打 error 日志
- 高风险键（模型名 / BASE_URL）的校验**必须在生效前完成**，不允许「先生效后回滚」

**3. Nacos 不可达**
- **启动时**：回退本地快照，打 warn 日志，**不阻塞启动**
- **运行中**：保持当前缓存值继续服务，打 warn 日志；恢复连接后自动重新订阅
- **本地快照也为空**（首次部署且 Nacos 不可达）：使用**代码内置默认值**，打 warn 日志

> **凭据默认值的例外**：代码内置默认值中**不得包含凭据**。现存问题：`cs/backend/app/config.py:42` 的 `mysql_url` 默认值明文写着 `csuser:cspass`，`cc/backend/app/config.py:18` 的 `mysql_password` 默认值是 `contract123`。**缺值就应该启动失败，而不是悄悄用一个开发密码连上去。** 改造时顺手清掉，避免把凭据默认值复制进新的配置层。

Update cadence / Lifecycle
--------------------------

| 配置类别 | 生效时机 | 依据 |
|---|---|---|
| Prompt（整段外置） | 收到推送后**立即**对新请求生效 | 本次新增能力 |
| 业务策略键（阈值、超时、TTL、开关） | 收到推送后**立即**生效 | 本次新增能力 |
| 高风险键（模型名 / BASE_URL） | 校验通过后立即生效 | 校验是前置门 |
| offline `scope=run` 的 14 键 | **创建 run 时快照，执行期不变** | 维持现状，不迁 |
| sp `scoring_rubric`、gq 切分参数 | 随实体创建时写入 | 维持现状，不迁 |
| offline `judge_rubric` | 随评测运行冻结 | 维持现状，不迁 |
| 凭据、部署形态 | 重启容器 | 维持现状，留 `.env` |

**版本追溯（必须做，不是优化项）**：agent 的 prompt 一旦可热更，offline 评测的「被测 prompt 版本」就说不清了——**prompt 热更一次，前后两次 run 的分数不可比，而报告里看不出差异来源**。现在 `_snapshot_run_config`（`api/runs.py:86`）只快照 `scope=run` 的 `system_config`，**不含 prompt 版本**。

因此：**被评测 agent 的 prompt 版本必须可追溯。**

> **机制已定（2026-09-21，见 `solution.md` §6）**：**不**往 run 快照里写 prompt 版本，改为「用 `run.started_at` + Nacos 版本历史（30 天）回溯」。理由是给 4 个 agent 各加采集端点属于「为将来可能留口子」，且「不做」的后果不构成具体故障。
> **本文档此处原先写作「必须进 run 快照」——那是把**结论**提前写进了范围文档。范围只该约束「必须可追溯」，具体机制由技术方案定。**

Future-proofing
---------------

- **新增项目接入**：范围定义与契约校验清单是逐项目独立的，新增 agent 时按同样格式补一节即可，不影响已改造项目。
- **新增配置项**：需要判断「该走 `.env` 还是 Nacos」时，复用「部署形态 vs 业务策略」判据；需要判断「该不该热更」时，复用 offline 的 `is_hot` 语义。
- **控制台权限**：若后续决定让业务用户在 Nacos 控制台直接改配置，需要先补细粒度 RBAC（开源版没有）——本设计未假设控制台对外。
- **凭据集中化**：若后续确有需求，应引入 Vault / K8s Secret / SOPS，**不要扩展本设计去承载凭据**。
- **会破坏兼容的变更**：把已迁入的配置项改回 `.env`、或改变 dataId 命名规范，都会造成配置静默丢失。

Implementation outline
----------------------

**范围已冻结。以下为后续阶段划分（技术方案开工前需另行细化的部分标注为「待方案」）。**

**批次 0：清理（与迁移分离，独立验收）**
- 删除 sp 的 2 个死键、online 的 5 个僵尸键
- 清理凭据默认值（cs / cc）
- 补齐 cc 的 `.env.example` 与 `Settings` 的同步
- **独立成批的理由**：迁移与清理混在一起，验收时分不清是哪一方的效果

**批次 1：infra 侧基座**
- 新增 `nacos` 组件，沿用既有惯例（compose service + `aliases: [nacos]` + `.env` 端口变量 + `init/` 初始化脚本）
- 存储方式、端口、命名空间规范 —— **待方案**

**批次 2：客户端基座（各仓自建）**
- `config_center` 薄封装：本地快照降级、监听推送、类型校验、契约校验
- 各仓无跨仓共享 Python 包，**须各自实现**；建议以 offline 的现有机制为模板
- SSRF host 白名单：cs / cc / gq 三家从零建

**批次 3 起：逐项目迁移**
- 顺序 **sp → cs → cc → gq → online → offline**
- 每批自问「这批的绿能证明什么、不能证明什么」
- **cs 的规则话术**须与 offline 断言对齐后才能改
- **offline 放最后**：它是唯一涉及评测可复现性的项目，且要等 prompt 版本进快照的机制验证过

Testing approach
----------------

**范围阶段的验证（本文档）**
- 本文档的每一条结论都有 `file:line` 依据；不接受无依据的断言
- 已实测并**推翻**两处初始判断（见「已修正的判断」）

**迁移阶段的验证（留技术方案细化）**
- **契约校验单测**：给定不合规 prompt，断言「拒绝加载 + 保留旧值」；给定合规 prompt，断言加载成功
- **降级路径**：Nacos 不可达时能起服务；本地快照为空时用代码默认值
- **跨项目一致性**：改 cs 规则话术后，offline 侧对应用例断言仍通过
- **端到端**：改一次 prompt → 观察生效 → 跑一次评测 → 校验评测结果可追溯到 prompt 版本

Acceptance criteria
-------------------

范围冻结的验收标准：

1. 六家各自的「上 Nacos」清单与「不上」清单已列明，**每一项「不上」都有理由**
2. 每份迁入的 prompt 都有对应的**契约校验清单**（必含标签 / 占位符 / 工具名）
3. 凭据与部署形态的边界已明确，且**逐键**分类完毕
4. 高风险键（模型名 / BASE_URL）已标识，且其**白名单前置条件**已明确
5. 「被测 prompt 版本必须可追溯」已作为必做项记录，并说明不做的后果；**具体机制由技术方案定**（已定：时间戳 + Nacos 30 天历史回溯，见 `solution.md` §6）

异常路径的验收标准：

- 给定一份缺失 `<thinking>` 标签的评分 prompt，**当**应用收到该配置推送，**则**拒绝加载、保留旧版、打 error 日志，且服务不中断
- 给定一个 host 不在白名单的 `base_url`，**当**应用收到该推送，**则**拒绝生效
- 给定 Nacos 不可达且本地无快照，**当**应用启动，**则**用代码内置默认值启动并打 warn 日志，**不阻塞启动**
- 给定一个 `EMBEDDING_MODEL_NAME` 的变更请求，**则**该键**不在**任何项目的迁入清单内（gq 除外项应为空）

---

附录：已修正的判断
------------------

本文档撰写过程中，有两处初始判断经实测被推翻，记录于此以免重蹈：

**1. 「agent-evaluation-offline 无 LLM prompt」——错。**
初始摸底报告称该平台不调用 LLM、无 prompt。实测证伪：`app/judge/rubric.py` 有带语义化版本号（`"1.2"` / `"1.1"`）的模板，`judge_rubric` 表有 `version` 列与 `(dimension_code, interface_id, version)` 唯一约束，`build_messages()` 从 rubric 模板组装裁判提示词，且 `rubric_version` 进入 verdict 缓存键。
**结论反而更强**：该平台不仅有 prompt，还已实现 prompt 版本化；但正因如此，它**不该**迁 Nacos（见 offline 一节）。

**2. 「smart-procurement 能一次验证 prompt 和配置两条线」——只对一半。**
选它当首个项目的理由之一是「能同时验证两条线」。实际核查发现：sp 的 system prompt 是**契约密集型文档**（含 `<thinking>/<answer>` 输出契约、`分数: <总分>` 格式契约、`<bid_content>` 输入契约、三处变量插值），且最该调优的评分口径 `scoring_rubric` **已经是数据驱动的 per-project 字段**。
**结论**：sp 适合验证**改造成本上限**（它的 prompt 最脏、最集中），但不适合验证**目标形态**——目标形态应参照 offline。

---

附录：本文档不覆盖的事项
------------------------

以下问题在讨论中已识别，但**不属于本次范围**，另行处理：

- **Nacos 控制台面向谁**：业务用户目前在用各项目的配置页面。若最终拆掉页面、让业务用户直连 Nacos 控制台，需要先补细粒度 RBAC（开源版无）。本设计**未假设控制台对外**。
- **凭据集中化**：见 Future-proofing。
- **infra 仓无 CI**：配置推送无人自动校验，只能靠人工。这是既有事实，本次引入 Nacos 不改变它。
- **页面去留**：本文档只定义「哪些配置上 Nacos」，不定义「页面拆不拆」。
