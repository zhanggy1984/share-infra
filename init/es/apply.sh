#!/bin/sh
# 幂等应用 obs ES index template + ILM 30d 策略（infra 落建快照）。
# 权威源 = online 仓 agent-evaluation-online/es-template/（防漂移注释互引，mapping 唯一源 backend consumer/es.py::_MAPPING）。
# 由 docker-compose 的 es-init 服务触发（depends_on elasticsearch healthy；restart: no，重跑幂等）。
set -e

: "${ES_URL:?需设置 ES_URL（如 http://elasticsearch:9200）}"
: "${ENV:?需设置 ENV（如 dev）}"
DIR=/init
CT='Content-Type: application/json'

# 等 ES 可连（depends_on healthy 已等过；这里兜底重试防启动竞态）
i=0
until curl -fsS "$ES_URL/_cluster/health" >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -ge 30 ] && { echo "es-init: ES 30s 未就绪，退出"; exit 1; }
  sleep 1
done

echo "[1/3] PUT ILM policy obs-ilm-30d"
curl -fsS -X PUT "$ES_URL/_ilm/policy/obs-ilm-30d" -H "$CT" -d @"$DIR/obs-ilm-policy.json" >/dev/null

for tpl in obs-event-template obs-log-template; do
  echo "[*] PUT index template $tpl (env=$ENV)"
  sed "s/\${ENV}/$ENV/g" "$DIR/$tpl.json" \
    | curl -fsS -X PUT "$ES_URL/_index_template/$tpl" -H "$CT" -d @- >/dev/null
done

echo "es-init OK (env=$ENV): obs-ilm-30d + obs-event/log-template 已就绪"
