#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
guard_edge
source "$(dirname "$0")/hive_env.sh"

log "=== Порты Hive Team C на edge ==="
pg_up=no; pg_running && pg_up=yes
hms_up=no; svc_running metastore && hms_up=yes
hs2_up=no; svc_running hiveserver2 && hs2_up=yes
check_hive_port "${PORT_PG}" "${pg_up}"
check_hive_port "${PORT_HMS}" "${hms_up}"
check_hive_port "${PORT_HS2}" "${hs2_up}"
check_hive_port "${PORT_HS2_WEB}" "${hs2_up}"

mkdir -p "${HIVE_HOME_DIR}" "${PG_RUN}" "${HIVE_LOG_DIR}" "${HIVE_PID_DIR}" "${HIVE_TMP}"
chmod 700 "${HIVE_HOME_DIR}"
if [ ! -s "${PG_PASS_FILE}" ]; then
  ( umask 077; openssl rand -hex 16 > "${PG_PASS_FILE}" )
fi
PG_PASS="$(cat "${PG_PASS_FILE}")"

log "=== PostgreSQL: база метаданных ==="
if [ ! -f "${PG_DATA}/PG_VERSION" ]; then
  "${PGBIN}/initdb" -D "${PG_DATA}" -U "${TEAM_USER}" -E UTF8 --locale=C \
    --auth-local=trust --auth-host=scram-sha-256 >/dev/null
  cat >> "${PG_DATA}/postgresql.conf" <<EOF
listen_addresses = '127.0.0.1'
port = ${PORT_PG}
unix_socket_directories = '${PG_RUN}'
max_connections = 50
shared_buffers = 64MB
jit = off
logging_collector = off
EOF
fi
if [ "${pg_up}" = no ]; then
  "${PGBIN}/pg_ctl" -D "${PG_DATA}" -l "${HIVE_LOG_DIR}/postgres.log" -w -t 60 start >/dev/null
fi
"${PGBIN}/pg_ctl" -D "${PG_DATA}" status | sed -n 1p
psql_c() { "${PGBIN}/psql" -h "${PG_RUN}" -p "${PORT_PG}" -U "${TEAM_USER}" -d postgres -v ON_ERROR_STOP=1 -qtAc "$1"; }
if [ "$(psql_c "SELECT 1 FROM pg_roles WHERE rolname='${METASTORE_DB_USER}'")" != 1 ]; then
  psql_c "CREATE ROLE ${METASTORE_DB_USER} LOGIN PASSWORD '${PG_PASS}'"
else
  psql_c "ALTER ROLE ${METASTORE_DB_USER} PASSWORD '${PG_PASS}'"
fi
if [ "$(psql_c "SELECT 1 FROM pg_database WHERE datname='${METASTORE_DB}'")" != 1 ]; then
  psql_c "CREATE DATABASE ${METASTORE_DB} OWNER ${METASTORE_DB_USER}"
fi
echo "PostgreSQL 127.0.0.1:${PORT_PG}, база ${METASTORE_DB}, пользователь ${METASTORE_DB_USER}"

log "=== hive-site.xml ==="
prop() { printf '  <property>\n    <name>%s</name>\n    <value>%s</value>\n  </property>\n' "$1" "$2"; }
{
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>\n<configuration>\n'
  prop javax.jdo.option.ConnectionURL                 "jdbc:postgresql://127.0.0.1:${PORT_PG}/${METASTORE_DB}"
  prop javax.jdo.option.ConnectionDriverName          "org.postgresql.Driver"
  prop javax.jdo.option.ConnectionUserName            "${METASTORE_DB_USER}"
  prop javax.jdo.option.ConnectionPassword            "${PG_PASS}"
  prop datanucleus.autoCreateSchema                   "false"
  prop datanucleus.schema.autoCreateAll               "false"
  prop hive.metastore.schema.verification             "true"
  prop hive.metastore.uris                            "thrift://${HIVE_HOST}:${PORT_HMS}"
  prop hive.metastore.port                            "${PORT_HMS}"
  prop metastore.thrift.port                          "${PORT_HMS}"
  prop hive.metastore.warehouse.dir                   "${HIVE_WAREHOUSE}"
  prop hive.metastore.warehouse.external.dir          "${HIVE_WAREHOUSE_EXT}"
  prop hive.metastore.event.db.notification.api.auth  "false"
  prop hive.server2.thrift.bind.host                  "0.0.0.0"
  prop hive.server2.thrift.port                       "${PORT_HS2}"
  prop hive.server2.transport.mode                    "binary"
  prop hive.server2.webui.host                        "0.0.0.0"
  prop hive.server2.webui.port                        "${PORT_HS2_WEB}"
  prop hive.server2.enable.doAs                       "false"
  prop hive.server2.authentication                    "NONE"
  prop hive.server2.logging.operation.log.location    "${HIVE_TMP}/operation_logs"
  prop hive.execution.engine                          "mr"
  prop hive.exec.scratchdir                           "/tmp/hive"
  prop hive.exec.local.scratchdir                     "${HIVE_TMP}/local"
  prop hive.downloaded.resources.dir                  "${HIVE_TMP}/resources"
  prop hive.querylog.location                         "${HIVE_TMP}/querylog"
  prop hive.exec.dynamic.partition                    "true"
  prop hive.exec.dynamic.partition.mode               "nonstrict"
  prop hive.support.concurrency                       "false"
  prop hive.txn.manager                               "org.apache.hadoop.hive.ql.lockmgr.DummyTxnManager"
  prop hive.strict.managed.tables                     "false"
  prop hive.create.as.insert.only                     "false"
  prop metastore.create.as.acid                       "false"
  prop hive.stats.autogather                          "false"
  echo '</configuration>'
} > "${HIVE_DIR}/conf/hive-site.xml"
chmod 600 "${HIVE_DIR}/conf/hive-site.xml"
cat > "${HIVE_DIR}/conf/hive-env.sh" <<EOF
export JAVA_HOME=${JAVA_DIR}
export HADOOP_HOME=${HADOOP_DIR}
export HADOOP_CONF_DIR=${HADOOP_DIR}/etc/hadoop
export HIVE_CONF_DIR=${HIVE_DIR}/conf
EOF
if [ -f "${HIVE_DIR}/conf/hive-log4j2.properties.template" ]; then
  sed "s#^property.hive.log.dir *=.*#property.hive.log.dir = ${HIVE_LOG_DIR}#" \
    "${HIVE_DIR}/conf/hive-log4j2.properties.template" > "${HIVE_DIR}/conf/hive-log4j2.properties"
fi
if grep -RniE 'team28a|team28b' "${HIVE_DIR}/conf" "${HADOOP_DIR}/etc/hadoop"; then die "в конфигах найдены пути других команд"; fi
if grep -nE ":($(echo ${FOREIGN_HIVE_PORTS} | tr ' ' '|'))[</]" "${HIVE_DIR}/conf/hive-site.xml"; then die "в hive-site.xml чужие порты"; fi
echo "hive-site.xml: ${HIVE_DIR}/conf/hive-site.xml"

log "=== HDFS-каталоги Hive ==="
hdfs dfs -mkdir -p /tmp/hive "${HIVE_WAREHOUSE}" "${HIVE_WAREHOUSE_EXT}" "${HIVE_RAW_DIR}"
hdfs dfs -chmod 1777 /tmp/hive "${HIVE_WAREHOUSE}" "${HIVE_WAREHOUSE_EXT}"
hdfs dfs -ls -d /tmp/hive "${HIVE_WAREHOUSE}" "${HIVE_WAREHOUSE_EXT}"

log "=== Схема Metastore в PostgreSQL ==="
if schematool -dbType postgres -info >/dev/null 2>&1; then
  echo "схема уже создана"
else
  schematool -dbType postgres -initSchema 2>&1 | grep -E 'Initialization script|schemaTool completed|Error|error' || true
  schematool -dbType postgres -info >/dev/null 2>&1 || die "не удалось создать схему Metastore"
fi
schematool -dbType postgres -info 2>/dev/null | grep -E 'Metastore connection URL|schema version' || true
log "Конфигурация Hive завершена."
