#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
guard_edge
source "$(dirname "$0")/hive_env.sh"
export SPARK_HOME="${SPARK_DIR}"

[ -x "${SPARK_DIR}/bin/spark-submit" ] || die "Spark не установлен — сначала ./deploy.sh spark-install"
svc_running metastore || die "Hive Metastore не запущен — ./deploy.sh hive-start"
hdfs dfs -test -e "${SPARK_INPUT}" || die "нет входных данных ${SPARK_INPUT} — сначала ./deploy.sh hive-load"

log "=== Порты Spark-драйвера на edge ==="
busy="$(ss -ltn | grep -E "$(ports_regex ${SPARK_PORTS})" || true)"
[ -z "${busy}" ] || { echo "${busy}"; die "порты Spark Team C заняты — выберите другие в config.env"; }
echo "свободны: ${SPARK_PORTS}"

log "=== Входные данные в HDFS ==="
hdfs dfs -ls "${SPARK_INPUT}"

log "=== spark-submit --master yarn ==="
LOG="${HIVE_TMP}/spark_job.log"
set +e
"${SPARK_DIR}/bin/spark-submit" --master yarn --deploy-mode client \
  --name team28c-sales-transform \
  "${REPO_DIR}/jobs/sales_transform.py" \
  "hdfs://${NN_HOST}:${PORT_NN_RPC}${SPARK_INPUT}" "${SPARK_DB}" "${SPARK_TABLE}" \
  "hdfs://${NN_HOST}:${PORT_NN_RPC}${SPARK_TABLE_PATH}" > "${LOG}" 2>&1
rc=$?
set -e
grep -vE ' (INFO|WARN) |^\s*$|^SLF4J|^WARNING' "${LOG}" | head -n 80
app="$(grep -oE 'application_[0-9]+_[0-9]+' "${LOG}" | sed -n 1p || true)"
echo "YARN application: ${app:-?}"
if [ "${rc}" != 0 ]; then
  grep -E 'Exception|Error' "${LOG}" | head -n 20
  die "Spark-задача завершилась с ошибкой (код ${rc}), полный лог: ${LOG}"
fi
log "Spark-задача выполнена. Полный лог: ${LOG}"
