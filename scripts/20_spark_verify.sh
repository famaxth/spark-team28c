#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
guard_edge
source "$(dirname "$0")/hive_env.sh"
FAIL=0
T="${SPARK_DB}.${SPARK_TABLE}"

log "=== Spark-приложение в YARN ==="
yarn application -list -appStates FINISHED 2>/dev/null | grep -E 'team28c-sales-transform' | tail -n 3 || { warn "приложение Spark не найдено в YARN"; FAIL=1; }

log "=== Партиции в HDFS (${SPARK_TABLE_PATH}) ==="
hdfs dfs -ls -R "${SPARK_TABLE_PATH}" | grep -E 'sale_month=[0-9]+$' || { warn "нет каталогов партиций"; FAIL=1; }

log "=== Чтение стандартным клиентом Hive (beeline) ==="
cat > "${HIVE_TMP}/spark_verify.sql" <<SQL
DESCRIBE FORMATTED ${T};
SHOW PARTITIONS ${T};
SELECT * FROM ${T} WHERE sale_year = 2025 AND sale_month = 1 ORDER BY revenue DESC LIMIT 5;
SQL
bl -f "${HIVE_TMP}/spark_verify.sql" 2>&1 | grep -E '^\|' | grep -E 'Table Type|Location|InputFormat|SerDe Library|spark.sql.sources.provider|partition|sale_year=|region|\| [A-Z][a-z]' | head -n 40 || true

parts="$(bl --outputformat=tsv2 --showHeader=false -e "SHOW PARTITIONS ${T}" 2>/dev/null | grep -c 'sale_year=' || true)"
echo "партиций в Metastore: ${parts}"
[ "${parts:-0}" -gt 0 ] || { warn "Hive не видит партиций таблицы"; FAIL=1; }

log "=== Сверка: агрегаты Spark-таблицы против исходной Hive-таблицы ${HIVE_DB}.sales ==="
cmp_sql="SELECT s.sale_year, s.sale_month, s.revenue AS spark_revenue, h.revenue AS hive_revenue, s.orders AS spark_orders, h.cnt AS hive_orders,
  CASE WHEN s.revenue = h.revenue AND s.orders = h.cnt THEN 'OK' ELSE 'DIFF' END AS check_result
FROM (SELECT sale_year, sale_month, sum(revenue) AS revenue, sum(orders) AS orders FROM ${T} GROUP BY sale_year, sale_month) s
JOIN (SELECT sale_year, sale_month, cast(sum(quantity * price) AS decimal(16,2)) AS revenue, count(*) AS cnt FROM ${HIVE_DB}.sales GROUP BY sale_year, sale_month) h
  ON s.sale_year = h.sale_year AND s.sale_month = h.sale_month
ORDER BY s.sale_year, s.sale_month"
out="$(bl -e "${cmp_sql}" 2>&1 | grep -E '^[|+]' || true)"
echo "${out}"
echo "${out}" | grep -q '| OK' || { warn "сверка не выполнилась"; FAIL=1; }
! echo "${out}" | grep -q 'DIFF' || { warn "данные Spark и Hive расходятся"; FAIL=1; }

echo
if [ "${FAIL}" = 0 ]; then
  log "SPARK TEAM C РАБОТАЕТ: сессия на YARN, чтение из HDFS, трансформации, партиционированная таблица ${T} читается клиентом Hive."
else
  die "Есть проблемы — см. вывод выше."
fi
