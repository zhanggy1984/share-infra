# 全链路耗时埋点 · 统一事件 Schema v1.0

> 目标：5 个 agent（good-question / customer-service / contract-check / smart-procurement / agent-evaluation-offline）+ api-gateway 统一耗时埋点。
> 形态：**一条请求/任务一条 JSON 事件**，同时携带 traceId + 业务结果 + 环节耗时明细。
> 演进：当前以日志输出；未来换 MQ 入 ES 时 **payload 不变，只换事件出口**。
>
> 本文档是 5 个后端 + 网关的共同契约，字段名/类型/枚举**不允许单边漂移**。

---

## 1. 核心原则

1. **事件必达**：无论成功、异常、超时、中断，每条请求/任务**必须有且仅有一条**事件日志。异常是最需要日志的时刻，异常时不产事件 = 信息黑洞。实现上在 `finally`/`except` 兜底 emit；若事件出口本身失败，降级打 stderr。
2. **部分耗时照记**：异常时**已完成的环节照常进 `timings`**，出错环节用 `error.stage` 标记，不做全盘丢弃。
3. **业务结果绑定**：事件必须带 `business`（有业务价值的字段）。纯耗时没有归因价值，带业务维度的耗时才有。
4. **统一 schema**：5 个后端同一结构，命名规范（§10）防止字段漂移。
5. **单向演进**：log → MQ → ES，只换出口。

---

## 2. 事件类型（event_type）

| event_type | 产生者 | 触发时机 | 说明 |
|---|---|---|---|
| `request` | 5 个后端 | HTTP 请求结束（SSE 为**全流结束**） | 常规接口 / 流式接口 |
| `task` | cc / eval 等 | 后台任务到达终态 | 无 HTTP 维度，只有业务维度 |
| `gateway` | api-gateway | nginx access_log 写入 | 外部视角总耗时，后端无日志时的兜底锚点 |

---

## 3. 顶层字段

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `schema_version` | string | Y | `"1.0"` |
| `event_type` | string | Y | `request` / `task` / `gateway` |
| `trace_id` | string | Y | 网关下发的 `X-Request-ID`（无网关时各端自生成的同值） |
| `service` | string | Y | 产生者：`good-question` / `customer-service` / `contract-check` / `smart-procurement` / `agent-evaluation-offline` / `api-gateway` |
| `type` | string | Y | 业务事件类型，见 §7；`gateway` 事件固定 `"-"` |
| `ts` | integer | Y | 时刻（epoch ms）。`request/task` = 后端入口/任务触发时刻；`gateway` = 请求完成时刻（起点用 `request_time` 反推） |
| `method` | string | N | HTTP 方法，仅 `request` |
| `path` | string | N | 请求路径（含 query），仅 `request` |
| `status` | integer | N | HTTP 状态码，仅 `request` |
| `total_ms` | integer | Y | 本服务内总耗时 ms（SSE 含全流）。`gateway` 事件不填此字段，用 §8 的 `request_time` |
| `result` | string | Y | `ok` / `error` / `canceled` / `rate_limited`（见 §5） |
| `remark` | string | N | 事件级**场景备注**（自由文本）：业务分支、降级、异常归因等结构化字段表达不了的信息。**事件成败看 `result`，场景说明看 `remark`**，两者不混 |
| `business` | object | Y | 业务结果，子结构见 §7 |
| `timings` | array[timing] | Y | 环节耗时明细（聚合条目）。**异常时也包含已完成环节** |
| `llm_calls` | array[llm_call] | N | LLM 调用明细（**涉及 LLM 的事件必填**），见 §3.3 |
| `error` | object | N | `result != ok` 时必填 |
| `warnings` | array[object] | N | 非致命告警（如某环节降级但整体成功） |

> **必填约束按 `event_type` 区分**：上表 `Y` 针对 `request/task` 事件；`gateway` 事件（nginx 日志）结构不同，仅含 §8 字段。schema.json 用 `oneOf` 分支实现，校验时按 `event_type` 生效。

### 3.1 timing 对象（timings 元素）

| 字段 | 类型 | 说明 |
|---|---|---|
| `name` | string | 环节名，`{stage}.{detail}` 命名，见 §10 |
| `dur_ms` | integer | 该环节累计耗时 ms（同环节多次自动聚合求和） |
| `cnt` | integer | 该环节发生次数 |
| `start_ms` | integer | 该环节**首次开始**相对事件起点 `ts` 的偏移 ms（链路时序还原用） |

> `timings` 是**聚合条目**而非每事件一行：同类环节（如 `loop.llm` 决策循环多轮）合并为一条 `{name, dur_ms, cnt, start_ms}`。SSE 大流不会把事件撑爆，ES nested 查询友好。未发生的环节**不出现**。`start_ms` 只记首次偏移，交错环节的精确顺序在 `llm_calls`（LLM 部分）里有完整明细。

### 3.2 error 对象

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `type` | string | Y | 标准错误码，枚举见 §6 |
| `message` | string | Y | 人读错误信息 |
| `stage` | string | N | 出错环节名（对应 `timings` 的 `name`），限流/网关拦截等无环节时省略 |
| `retries` | integer | N | 重试次数 |

### 3.3 llm_call 对象（llm_calls 元素）

涉及 LLM 的事件，**每次 LLM 调用一条明细**（时间 + 结果 + token 三要素）。

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `name` | string | Y | 环节名（对应 `timings` 的 `name`，如 `loop.llm`） |
| `status` | string | Y | `ok` / `error` / `timeout` |
| `dur_ms` | integer | Y | 单次调用耗时 ms（含重试累计） |
| `in_tokens` | integer | Y | 输入 token（无则 0） |
| `out_tokens` | integer | Y | 输出 token（无则 0） |
| `all_tokens` | integer | Y | 总 token（取 `usage.total_tokens`；不可得时 = `in_tokens + out_tokens` 或 0） |
| `retries` | integer | N | 重试次数 |

> **一致性约束**：`timings` 中的 `llm.*` 聚合条目由 `llm_calls` 在 emit 时**汇总生成**（同 `name` 累计 `dur_ms`、`cnt` 计次、token 求和），不得双处独立填写。

---

## 4. 正常事件示例

### 4.1 request 正常（cs 对话，SSE 全流结束）

```json
{
  "schema_version": "1.0",
  "event_type": "request",
  "trace_id": "91253785c7a94b12a3d6f1e8b2c4d5f6",
  "service": "customer-service",
  "type": "message",
  "ts": 1788000000123,
  "method": "POST",
  "path": "/api/v1/sessions/s-123/messages",
  "status": 200,
  "total_ms": 12400,
  "result": "ok",
  "remark": "决策循环第 3 轮调用工具后走订单状态机",
  "business": {
    "session_id": "s-123",
    "intent": "order",
    "route": "business_flow",
    "tool_calls": 2,
    "tokens": {"in": 512, "out": 808, "all": 1320}
  },
  "timings": [
    {"name": "lock", "dur_ms": 3, "cnt": 1, "start_ms": 0},
    {"name": "intent.llm", "dur_ms": 1200, "cnt": 1, "start_ms": 10},
    {"name": "loop.llm", "dur_ms": 3800, "cnt": 3, "start_ms": 1300},
    {"name": "tool.exec", "dur_ms": 210, "cnt": 2, "start_ms": 2500},
    {"name": "stream.llm", "dur_ms": 5100, "cnt": 1, "start_ms": 5400},
    {"name": "db.save", "dur_ms": 85, "cnt": 2, "start_ms": 10600}
  ],
  "llm_calls": [
    {"name": "intent.llm", "status": "ok", "dur_ms": 1200, "in_tokens": 180, "out_tokens": 60, "all_tokens": 240},
    {"name": "loop.llm", "status": "ok", "dur_ms": 1500, "in_tokens": 300, "out_tokens": 220, "all_tokens": 520},
    {"name": "loop.llm", "status": "ok", "dur_ms": 1200, "in_tokens": 340, "out_tokens": 240, "all_tokens": 580},
    {"name": "loop.llm", "status": "ok", "dur_ms": 1100, "in_tokens": 350, "out_tokens": 250, "all_tokens": 600},
    {"name": "stream.llm", "status": "ok", "dur_ms": 5100, "in_tokens": 200, "out_tokens": 380, "all_tokens": 580}
  ]
}
```

### 4.2 task 正常（cc 校验任务完成）

```json
{
  "schema_version": "1.0",
  "event_type": "task",
  "trace_id": "ebd8979153f04a11b2c3d4e5f6a7b8c9",
  "service": "contract-check",
  "type": "upload_check",
  "ts": 1788000000123,
  "total_ms": 48000,
  "result": "ok",
  "remark": "检出 1 条 violation，转人工审核",
  "business": {
    "task_id": 1024,
    "file_sha": "9f86d081884c7d659a2feaa0c55ad015",
    "segments": 3,
    "violations": 1,
    "status": "WAITING_REVIEW",
    "tokens": {"in": 8200, "out": 3400, "all": 11600}
  },
  "timings": [
    {"name": "llm.extract", "dur_ms": 18000, "cnt": 3, "start_ms": 5000},
    {"name": "llm.semantic", "dur_ms": 16000, "cnt": 1, "start_ms": 26000},
    {"name": "sparql", "dur_ms": 700, "cnt": 24, "start_ms": 43000},
    {"name": "db.persist", "dur_ms": 420, "cnt": 1, "start_ms": 46000}
  ]
}
```

> 注意：cc 检出 violation 转人工审核（`status=WAITING_REVIEW`）是**正常完成**，`result=ok`，业务状态放 `business.status`。只有流程本身失败才 `result=error`。

---

## 5. result 枚举与异常情况矩阵

| 场景 | 产生者 | `result` | `error.type` | `timings` | 说明 |
|---|---|---|---|---|---|
| 业务正常完成 | 后端 | `ok` | — | 全部环节 | 含"业务需人工介入但流程正常"（如 cc WAITING_REVIEW） |
| 参数校验失败 422 | 后端 | `error` | `VALIDATION_ERROR` | 仅已完成环节（通常空） | |
| 认证失败 401/403 | 后端 | `error` | `AUTH_FAILED` | 仅鉴权前环节 | |
| LLM 调用失败/重试耗尽 | 后端 | `error` | `LLM_UNAVAILABLE` | 已完成环节 + 出错 stage | stage=对应 llm.* |
| LLM 超时 | 后端 | `error` | `LLM_TIMEOUT` | 已完成环节 + 出错 stage | |
| DB 失败/超时 | 后端 | `error` | `DB_ERROR` / `DB_TIMEOUT` | 已完成环节 + 出错 stage | |
| 业务流程失败（cc FAILED / eval run 失败） | 后端 | `error` | `TASK_FAILED` | 已完成环节 | |
| **后台任务超时**（cc 600s / eval run_timeout） | 后端 | `error` | `TASK_TIMEOUT` | 已完成环节 | 超时点所在 stage |
| **SSE 客户端中断** | 后端 | `canceled` | `CLIENT_DISCONNECT` | 已发生环节 | generator `finally` 里 emit，**不能依赖 done 事件** |
| 网关限流 503 | api-gateway | `rate_limited` | `RATE_LIMITED` | 无后端环节 | 只有 gateway 事件 |
| 未知 Host 403 | api-gateway | `error` | `BAD_HOST` | 无后端环节 | 只有 gateway 事件 |
| 后端不可达 502 | api-gateway | `error` | `UPSTREAM_UNAVAILABLE` | 无后端环节 | gateway 事件，`upstream_response_time` 为空 |
| 后端超时 504 | api-gateway | `error` | `UPSTREAM_TIMEOUT` | 无后端环节 | gateway 事件 |
| 网关内部错误 | api-gateway | `error` | `GATEWAY_ERROR` | 无后端环节 | |
| 后端内部未捕获异常 500 | 后端 | `error` | `INTERNAL_ERROR` | 已完成环节 | 必须 emit（兜底） |
| 部分成功（eval 部分 case 通过） | 后端 | `error` | `TASK_FAILED` | 全部环节 | 通过数放 `business.cases_passed` |

### 5.1 result 取值约束

- `ok`：业务流程正常完成（含业务分支判定，如 cc 转人工审核）。
- `error`：服务端/上游错误、业务失败、校验/鉴权失败、超时。
- `canceled`：仅客户端主动中断（SSE 断开）。
- `rate_limited`：仅网关限流拦截。

> **关键规则**：网关 502/504/503 时后端可能完全没收到请求，**只有 gateway 事件，没有后端事件**——这是"无后端事件"唯一合理的情形。除此之外，任何 `trace_id` 出现请求但查不到后端事件，即为埋点缺陷（§1 事件必达违规）。

### 5.2 result vs remark 分工

- **`result`**：机器判定的事件成败（枚举），评测端分类统计、告警的键。
- **`remark`**：业务代码补充的**场景备注**（自由文本，可选）："缓存命中直接回复"、"检出 2 条 violation 转人工审核"、"8/10 case 通过"、"客户端第 40s 断开"、"LLM 重试 2 次后成功"。查询端按 `result` 筛、按 `remark` 快速定位场景，不用从 `timings`/`business` 反推。

---

## 6. 标准错误码（error.type 枚举，全量）

| 错误码 | 含义 |
|---|---|
| `LLM_TIMEOUT` | LLM 调用超时（单次或累计） |
| `LLM_UNAVAILABLE` | LLM 返回失败/重试耗尽/熔断 |
| `LLM_RESPONSE_INVALID` | LLM 响应无法解析（如 JSON 抽取失败） |
| `DB_ERROR` | 数据库错误（连接、约束、死锁重试耗尽） |
| `DB_TIMEOUT` | 数据库查询超时 |
| `TASK_TIMEOUT` | 后台任务整体超时 |
| `TASK_FAILED` | 后台任务业务失败 |
| `UPSTREAM_UNAVAILABLE` | 网关到后端连接失败 |
| `UPSTREAM_TIMEOUT` | 网关到后端超时 |
| `RATE_LIMITED` | 网关限流拦截（503） |
| `BAD_HOST` | 网关未知 Host（403） |
| `AUTH_FAILED` | 认证/授权失败（401/403） |
| `VALIDATION_ERROR` | 参数校验失败（422） |
| `CLIENT_DISCONNECT` | 客户端主动断开（SSE） |
| `INTERNAL_ERROR` | 后端未捕获异常（500） |

> 各 agent 的 LLM/DB 具体异常**必须映射到上表**，禁止自造不在枚举内的类型。映射逻辑收敛在各后端的 `timing.py` 或统一异常处理器。

---

## 7. 各 agent 的 type / business / 环节清单

> **business 防漂移**：以下 `business` 子结构是权威定义，机器可读版见 `docs/timing-event.schema.json`（`definitions.business_*`）。防漂移三层防线见 §13。

### 7.1 good-question（type: `chat`）

| 环节名 | 锚点 | 说明 |
|---|---|---|
| `session.load` | `chat_service._get_owned_session` | 会话归属校验 |
| `cache` | `chat_cache.get_cached` | 缓存命中判定 |
| `llm.round1` | `_stream_deepseek`（chat_service.py:641） | 第一轮 LLM（推理+内容+工具） |
| `rag.embed` | `embedding_service.py:63` | 查询向量化 |
| `rag.milvus` | `vector_store_service.py:101` | Milvus 混合检索 |
| `rag.rerank` | `rerank.py:67` | 精排 top-3 |
| `rag.expand` | `retrieval_service.py:86` | 章节扩充额外检索 |
| `llm.round2` | `chat_service.py:960` | 命中检索后的第二轮 LLM |
| `db.save` | `_save_messages` | 写会话消息 |
| `memory.compress` | `_compress_memory` | 记忆压缩 LLM |
| `ttft` | `stream_chat` 入口 → 首 token | 首 token 延迟 |

`business`: `session_id`, `cache_hit`(bool), `sources_count`, `tokens{in,out,all}`

### 7.2 customer-service（type: `message`）

| 环节名 | 锚点 |
|---|---|
| `lock` | `RedisSessionLock` 获取 |
| `session.load` | `session_manager.get_session` |
| `intent.llm` | `classify_intent` LLM 调用 |
| `loop.llm` | `agent_loop` 决策循环（每轮计一次，聚合 cnt） |
| `tool.exec` | `executor.execute`（含护栏） |
| `flow` | 业务状态机 step |
| `rag.embed` / `rag.milvus` / `rag.rerank` / `rag.expand` | policy 检索 |
| `stream.llm` | `chat_stream` 流式生成 |
| `db.save` | 消息/会话落库 |

`business`: `session_id`, `intent`, `route`, `tool_calls`, `tokens{in,out,all}`

### 7.3 contract-check（type: `upload_check`，后台 task）

| 环节名 | 锚点 |
|---|---|
| `upload` | 文件写入 |
| `extract.text` | PDF/DOCX 文本抽取 |
| `ocr` | 扫描件 OCR（懒加载模型，可能最慢） |
| `llm.extract` | `llm_client.call_json` 抽取（分段并发，聚合 cnt） |
| `rdf.convert` | JsonToRdfConverter |
| `sparql` | SparqlExecutor 逐规则 |
| `llm.semantic` | 语义评估（分段，聚合 cnt） |
| `db.persist` | 全量落库（含死锁重试） |

`business`: `task_id`, `file_sha`, `segments`, `violations`, `status`(SUCCESS/FAILED/WAITING_REVIEW/INCOMPLETE), `tokens{in,out,all}`

### 7.4 smart-procurement（type: `review_score` / `chat`）

| 环节名 | 锚点 |
|---|---|
| `auth` | `get_current_user`（JWT+DB） |
| `db.query` | 单接口内 MySQL 查询（聚合 cnt） |
| `neo4j.conflict` | 专家冲突检测 |
| `minio.upload` | 标书上传 |
| `rag.embed` / `rag.milvus` | RAG 检索 |
| `llm.stream` | `chat_stream` 评分/对话流式 |
| `llm.summarize` | 对话第 4 轮摘要（注意其绕过统一客户端） |
| `arq.enqueue` | 文档入库投递 |

`business`: `review_id`, `dimension`, `cache_hit`(bool), `tokens{in,out,all}`

### 7.5 agent-evaluation-offline（type: `eval_run`，后台 task）

| 环节名 | 锚点 |
|---|---|
| `run.create` | 触发评测落库 + create_task |
| `probe` | 跑前契约探测（每 interface） |
| `agent.call` | `execute_case` 调评测对象（并发，聚合 cnt） |
| `judge.llm` | JudgeClient 判分 LLM |
| `scorer` | 评分计算 |
| `db.query` | 门禁/分页 DB 聚合 |

`business`: `run_id`, `agent`, `suite`, `cases_total`, `cases_passed`, `score`, `status`(pending/running/scoring/completed/failed/timeout), `judge_tokens{in,out,all}`

---

## 8. 网关日志（gateway 事件，nginx access_log）

`conf.d/gateway.conf` 增加：

```nginx
log_format timing_json escape=json
  '{"schema_version":"1.0","event_type":"gateway","trace_id":"$request_id",'
  '"service":"api-gateway","type":"-","ts":$msec,"method":"$request_method",'
  '"path":"$request_uri","status":$status,"upstream_status":"$upstream_status",'
  '"request_time":$request_time,"connect_time":$upstream_connect_time,'
  '"header_time":$upstream_header_time,"response_time":$upstream_response_time,'
  '"remote_addr":"$remote_addr"}';
access_log /var/log/nginx/access.log timing_json;
```

| nginx 变量 | 语义 | 异常时取值 |
|---|---|---|
| `request_time` | 网关收到请求到响应完成（**SSE 含全流**） | 恒有值 |
| `upstream_response_time` | 后端处理+网络耗时 | 后端未响应时为空（502/504） |
| `upstream_connect_time` | 到后端连接耗时 | 连接失败时为空 |
| `upstream_header_time` | 到收到后端响应头耗时 | — |
| `upstream_status` | 后端状态码 | 未响应时为空 |

- `ts` = 请求完成时刻（`$msec`，nginx 写日志时）；若要请求起点，用 `ts - request_time` 近似。
- **gateway 事件不含 `total_ms`**（字段结构不同），外部总耗时直接看 `request_time`。
- **gateway 事件不适用 §3 的 `result/business/timings` 必填约束**（结构不同，由 schema.json 的 `oneOf` 分支区分）。
- 网关日志是**外部视角锚点**：评测端拿一次请求的 `gateway` 事件（外部总耗时）+ 对应后端 `request/task` 事件（服务内总耗时 + 环节耗时），即得"用户感知 vs 服务处理"两层视图。

---

## 9. 时序与对齐

- **起点**：`request/task` 事件的 `ts` = 后端入口时刻（中间件收到请求 / 后台任务触发）。
- **对齐**：所有时间戳为**绝对 epoch ms**。网关和后端各自记录，同机/同 docker 网络内时钟偏差可忽略，无需分布式时钟协议。评测端按 `trace_id` 关联后直接排序即得完整时间线。
- **SSE 计时位置（关键陷阱）**：FastAPI 中间件 `call_next` 返回时**流才刚开始**，中间件计时测不到全流。gq/cs/sp 的 `total_ms` 与 `ttft` 必须在 **generator 内部**（done 事件处 / `finally`）计算，**不能**在中间件里算。

### 9.1 链路查询视角（按 traceId 还原一整条运行链路）

**单请求链路**：同一 `trace_id` 下按 `ts` 排序：`gateway` 事件（外部总耗时 `request_time`）→ 后端 `request/task` 事件（服务内 `total_ms` + `timings`，`start_ms` 还原环节时间线）。`llm_calls` 提供 LLM 调用的完整顺序明细。

**跨请求业务链路（后台任务继承 traceId）**：cc 上传→后台校验、eval 触发→后台 run 这类"请求 + 后台任务"两步，**后台任务必须继承触发请求的 `trace_id`**（`asyncio.create_task`/`asyncio.to_thread` 默认复制当前 contextvar）。这样一条 traceId 就能看到"上传 + 后台校验"或"触发 + 整个 run"的完整链路。实现时逐后端**实测 contextvar 传播**（§10.7），不满足则显式传参。

**跨服务链路（评测平台 → 被测 agent）**：网关对每个新请求**强制生成新 traceId**（见 gateway.conf `proxy_set_header X-Request-ID $request_id`），评测平台调被测 agent 时链路在网关处断。当前设计按**两级串联**查询：评测平台事件（`business.run_id` + 记录被测 agent 响应头 `X-Request-ID`）→ 被测 agent 事件（各自 `trace_id`）。**是否改为网关透传上游 traceId（一条贯穿）是待定决策，默认保持强制生成。**

---

## 10. 埋点约定

1. **命名规范**：`timings[].name` 用 `{stage}.{detail}`，统一小写、`.` 分隔（`rag.milvus`、`loop.llm`、`db.save`）。stage 取 §7 各表清单，**不得自创未登记的 stage**（新增需回本文档登记）。
2. **只埋汇聚点**：优先在唯一汇聚点插桩（cc 的 `llm_client.call_json`、cs 的 `DeepSeekGateway`、gq 的 `_stream_deepseek`），一个点覆盖全部同类调用。不做函数级插桩。
3. **未发生的环节不出现**：`timings` 中不存在 = 未发生或未埋，评测端按此理解。
4. **LLM 调用明细（`llm_calls`）**：涉及 LLM 的事件必须输出 `llm_calls`——**每次 LLM 调用一条**，含 `name/status(ok|error|timeout)/dur_ms/in_tokens/out_tokens/retries`。`timings` 的 `llm.*` 聚合条目由 `llm_calls` emit 时汇总（同 `name` 累计 `dur_ms`、`cnt` 计次、token 求和），不做"首试/重试"拆分（重试合并记入同一条，`retries` 记次数）。
5. **token 来源**：LLM 响应 `usage`（OpenAI 兼容 `prompt_tokens`/`completion_tokens`）；**流式在流结束取**（`stream_options.include_usage`）；无法取得记 0。sp 的 `conversation_service._summarize_with_llm`（绕过统一客户端的裸 `AsyncOpenAI`）必须同样接入记录点，否则 token/耗时漏记。
6. **事件必达实现**：`emit()` 必须在 `finally` 中调用；SSE 流在 generator 的 `finally`（`done` 事件可能因中断不发）。`emit` 自身失败降级 `logger.error` 原始字符串。
7. **跨线程 contextvar**：cc 的 `to_thread` 线程池、sp 的阻塞 IO `to_thread`，须确认 contextvar（计时表/trace_id）随 `asyncio.to_thread` 传播（默认复制当前 context），实施时**逐后端实测**，不满足则显式传参。
8. **每后端复制 `timing.py`**（~60 行）：contextvar 计时表 + `begin()/mark()/finish()/set_business()` + 异常映射 + business 白名单校验。不引入 Python 包分发，贴合 TraceIdMiddleware 复制先例。

---

## 11. 演进：log → MQ → ES

- 当前：`emit()` 写结构化 JSON 日志（gq/cc 需加 JsonFormatter，cs/eval 复用现有，sp 用 structlog）。
- 未来：`emit()` 换成 MQ producer，消息体即 §3 顶层事件，**schema 不变**；ES 按 `trace_id` 建索引，`timings` 用 nested 类型。
- schema 升级：`schema_version` 递增，5 个后端 + 网关同步，升级窗口内下游按版本兼容消费。

---

## 12. 异常覆盖自查清单（写代码时逐条过）

- [ ] LLM 超时 → `error.type=LLM_TIMEOUT`，stage 指向出错环节，已完成环节仍在 `timings`
- [ ] LLM 重试耗尽 → `LLM_UNAVAILABLE` + `retries`
- [ ] DB 死锁重试 3 次仍失败 → `DB_ERROR`（cc persist 节点）
- [ ] 后台任务 600s 超时 → `TASK_TIMEOUT`（cc `_go` / eval run_timeout）
- [ ] SSE 客户端断开 → `canceled`/`CLIENT_DISCONNECT`，generator `finally` emit
- [ ] 网关限流 503 / 未知 Host 403 / 502 / 504 → 只有 gateway 事件
- [ ] 未捕获异常 500 → `INTERNAL_ERROR` 兜底 emit
- [ ] eval 部分 case 失败 → `error` + `business.cases_passed` 体现通过数
- [ ] 涉及 LLM 的事件输出 `llm_calls`（每次调用一条：status/dur/tokens/retries），`timings` 的 `llm.*` 由它汇总
- [ ] token 取自 LLM 响应 `usage`（`all_tokens` = `usage.total_tokens`，流式在流结束取），取不到记 0
- [ ] `set_business()` 运行时白名单校验通过（无 warning）
- [ ] `test_timing_business.py` 单测通过（成功 + 异常样例）
- [ ] `timings[].start_ms` 已记录（该环节首次开始偏移，链路时序用）
- [ ] 后台任务（cc 校验 / eval run）复用触发请求的 trace_id（实测 contextvar 传播）
- [ ] 关键业务分支/降级/异常归因写 `remark` 场景备注（如"命中缓存直接回复"、"转人工审核"、"部分 case 失败"）

---

## 13. business 字段防漂移机制

### 13.1 单一事实来源

`docs/timing-event.schema.json`（本目录，与本文档同源）是 `business` / `timings` / `llm_calls` / `error` 的**唯一权威定义**。5 个后端**不得**自行增删字段；新增/改名必须：① 改 schema.json + 本文档 §7 → ② 同步复制到各后端 → ③ 跑单测。

### 13.2 三层防线

| 层 | 机制 | 位置 | 作用 |
|---|---|---|---|
| 1 | **运行时白名单校验**（primary） | 各后端 `timing.py` 内置 `BUSINESS_KEYS`（从 schema.json 派生，随复制同步）；`set_business()` 校验 | 未知 key / 缺必填 / 类型不符 → 打 warning（不阻断业务，日志明示漂移） |
| 2 | **单测兜底**（CI） | 各后端 `test_timing_business.py`，**直接用完整 schema 校验真实事件样例**（顶层 `business` 已 `anyOf` 引用全部 `business_*`，自动严格校验；成功 + 异常各一例） | 无 `jsonschema` 依赖时手写断言（key 集合 + 类型检查） |
| 3 | **文档 + 审码** | 本文档 §7 | 人工对齐最后一道 |

### 13.3 同步与升级

- `timing-event.schema.json` 与 `timing.py` 一起复制到各后端（建议 `backend/timing/` 或 `backend/core/timing/`）。
- 升级流程：改 infra 单一来源 → 各后端复制 + 跑单测 → 验收；`schema_version` 递增。
- 运行时校验成本：`set_business()` 仅做 dict key 集合 + 类型检查，微秒级，可忽略。
