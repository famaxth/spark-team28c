#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
guard_edge
source "$(dirname "$0")/hive_env.sh"

svc_running hiveserver2 || die "HiveServer2 не запущен — сначала ./deploy.sh hive"

SRC="${1:-}"
WORK="${HIVE_TMP}/load"
mkdir -p "${WORK}"
if [ -z "${SRC}" ]; then
  SRC="${WORK}/sales.csv"
  log "Генерирую тестовые данные ${SRC}"
  python3 - "${SRC}" <<'PY'
import csv, random, sys, datetime
random.seed(28)
regions = ["Moscow", "Saint-Petersburg", "Kazan", "Novosibirsk", "Yekaterinburg"]
products = ["laptop", "phone", "tablet", "monitor", "keyboard", "mouse"]
start = datetime.date(2025, 1, 1)
with open(sys.argv[1], "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["id", "sale_date", "region", "product", "quantity", "price"])
    for i in range(1, 20001):
        d = start + datetime.timedelta(days=random.randrange(181))
        w.writerow([i, d.isoformat(), random.choice(regions), random.choice(products),
                    random.randint(1, 5), f"{random.uniform(5, 2000):.2f}"])
PY
fi
[ -s "${SRC}" ] || die "нет файла ${SRC}"
if [ "${SRC}" != "${WORK}/sales.csv" ]; then sed 's/\r$//' "${SRC}" > "${WORK}/sales.csv"; else sed -i 's/\r$//' "${SRC}"; fi
SRC="${WORK}/sales.csv"
echo "файл: ${SRC}, строк: $(($(wc -l < "${SRC}") - 1))"
case "$(head -n 1 "${SRC}")" in
  id,sale_date,region,product,quantity,price) ;;
  *) die "ожидается CSV с заголовком id,sale_date,region,product,quantity,price" ;;
esac

log "=== Загрузка файла в HDFS ${HIVE_RAW_DIR} ==="
hdfs dfs -mkdir -p "${HIVE_RAW_DIR}"
hdfs dfs -put -f "${SRC}" "${HIVE_RAW_DIR}/sales.csv"
hdfs dfs -ls "${HIVE_RAW_DIR}"

log "=== Таблицы Hive и загрузка в партиционированную таблицу ==="
cat > "${WORK}/load.sql" <<SQL
CREATE DATABASE IF NOT EXISTS ${HIVE_DB};
USE ${HIVE_DB};

CREATE EXTERNAL TABLE IF NOT EXISTS sales_raw (
  id BIGINT,
  sale_date DATE,
  region STRING,
  product STRING,
  quantity INT,
  price DECIMAL(10,2)
)
ROW FORMAT DELIMITED FIELDS TERMINATED BY ','
STORED AS TEXTFILE
LOCATION '${HIVE_RAW_DIR}'
TBLPROPERTIES ('skip.header.line.count'='1');

CREATE TABLE IF NOT EXISTS sales (
  id BIGINT,
  sale_date DATE,
  region STRING,
  product STRING,
  quantity INT,
  price DECIMAL(10,2)
)
PARTITIONED BY (sale_year INT, sale_month INT)
STORED AS ORC;

SET hive.exec.dynamic.partition=true;
SET hive.exec.dynamic.partition.mode=nonstrict;

INSERT OVERWRITE TABLE sales PARTITION (sale_year, sale_month)
SELECT id, sale_date, region, product, quantity, price,
       year(sale_date) AS sale_year, month(sale_date) AS sale_month
FROM sales_raw
WHERE sale_date IS NOT NULL;

SHOW PARTITIONS sales;
SELECT sale_year, sale_month, count(*) AS cnt, round(sum(quantity * price), 2) AS revenue
FROM sales GROUP BY sale_year, sale_month ORDER BY sale_year, sale_month;
SQL
bl -f "${WORK}/load.sql" 2>&1 | grep -vE '^(SLF4J|WARNING:)' | grep -vE 'INFO|^$' || true

log "=== Партиции в HDFS ==="
loc="$(bl --outputformat=tsv2 --showHeader=false -e "DESCRIBE FORMATTED ${HIVE_DB}.sales" 2>/dev/null | grep -E '^Location:' | grep -oE 'hdfs://[^[:space:]]+' | sed -n 1p || true)"
echo "Location: ${loc}"
[ -n "${loc}" ] && hdfs dfs -ls -R "${loc}" | grep -E 'sale_month=[0-9]+$' || true
n="$(bl --outputformat=tsv2 --showHeader=false -e "SELECT count(*) FROM ${HIVE_DB}.sales" 2>/dev/null | tr -d '[:blank:]' | grep -E '^[0-9]+$' | tail -n 1 || true)"
p="$(bl --outputformat=tsv2 --showHeader=false -e "SHOW PARTITIONS ${HIVE_DB}.sales" 2>/dev/null | grep -c 'sale_year=' || true)"
echo "строк в ${HIVE_DB}.sales: ${n:-?}, партиций: ${p}"
[ "${p}" -gt 0 ] && [ "${n:-0}" -gt 0 ] || die "данные не загрузились"
log "Данные загружены в партиционированную таблицу ${HIVE_DB}.sales."
