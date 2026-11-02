#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
guard_edge
source "$(dirname "$0")/hive_env.sh"
FAIL=0

log "=== Сервисы Hive Team C (${HIVE_HOST}) ==="
if pg_running; then echo "PostgreSQL: работает (127.0.0.1:${PORT_PG})"; else warn "PostgreSQL не работает"; FAIL=1; fi
for s in metastore hiveserver2; do
  if svc_running "${s}"; then echo "${s}: работает (pid $(cat "${HIVE_PID_DIR}/${s}.pid"))"; else warn "${s} не работает"; FAIL=1; fi
done
ss -ltn | grep -E "$(ports_regex ${HIVE_PORTS})" || true

log "=== Metastore хранит метаданные в PostgreSQL ==="
"${PGBIN}/psql" -h "${PG_RUN}" -p "${PORT_PG}" -U "${TEAM_USER}" -d "${METASTORE_DB}" -qtA -F ' | ' -c \
  "SELECT d.\"NAME\", t.\"TBL_NAME\", t.\"TBL_TYPE\", count(p.\"PART_ID\") FROM \"TBLS\" t JOIN \"DBS\" d ON d.\"DB_ID\"=t.\"DB_ID\" LEFT JOIN \"PARTITIONS\" p ON p.\"TBL_ID\"=t.\"TBL_ID\" GROUP BY 1,2,3 ORDER BY 1,2" \
  || { warn "не удалось прочитать метаданные из PostgreSQL"; FAIL=1; }

log "=== Одновременная работа нескольких клиентов через HiveServer2 ==="
OUT="${HIVE_TMP}/verify"; mkdir -p "${OUT}"
q1="SELECT 'client-1' AS client, count(*) AS partitions FROM (SELECT DISTINCT sale_year, sale_month FROM ${HIVE_DB}.sales) t"
q2="SELECT 'client-2' AS client, region, quantity, price FROM ${HIVE_DB}.sales WHERE sale_year=2025 AND sale_month=3 LIMIT 3"
q3="SHOW PARTITIONS ${HIVE_DB}.sales"
i=0
for q in "${q1}" "${q2}" "${q3}"; do
  i=$((i + 1))
  ( bl -e "${q}" > "${OUT}/client${i}.out" 2>&1; echo $? > "${OUT}/client${i}.rc" ) &
done
wait
for i in 1 2 3; do
  rc="$(cat "${OUT}/client${i}.rc")"
  echo "--- клиент ${i}: код возврата ${rc}"
  grep -E '^[|+]' "${OUT}/client${i}.out" | head -n 12 || true
  [ "${rc}" = 0 ] || { warn "клиент ${i} завершился с ошибкой"; tail -n 5 "${OUT}/client${i}.out"; FAIL=1; }
done

log "=== HiveServer2 Web UI ==="
code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "http://127.0.0.1:${PORT_HS2_WEB}/" || true)"
echo "http://127.0.0.1:${PORT_HS2_WEB}/ -> HTTP ${code}"
case "${code}" in 200|302) ;; *) warn "Web UI HiveServer2 не отвечает"; FAIL=1;; esac

log "=== Логи Hive ==="
for f in "${HIVE_LOG_DIR}"/*.out "${HIVE_LOG_DIR}"/hive.log; do
  [ -f "${f}" ] || continue
  c="$(grep -cE '(^| )(FATAL|ERROR) ' "${f}" || true)"
  echo "$(basename "${f}"): ERROR/FATAL строк: ${c}"
  [ "${c}" = 0 ] || grep -E '(^| )(FATAL|ERROR) ' "${f}" | tail -n 3
done

echo
if [ "${FAIL}" = 0 ]; then
  log "HIVE TEAM C РАБОТАЕТ: PostgreSQL + Metastore + HiveServer2, несколько клиентов одновременно, таблица ${HIVE_DB}.sales партиционирована."
  echo "Подключение клиента: beeline -u ${HS2_URL} -n ${TEAM_USER}"
  echo "Web UI HiveServer2 через туннель: ssh -N -L ${PORT_HS2_WEB}:127.0.0.1:${PORT_HS2_WEB} ${TEAM_USER}@${EDGE_PUBLIC_IP}  ->  http://localhost:${PORT_HS2_WEB}/"
else
  die "Есть проблемы — см. вывод выше."
fi
