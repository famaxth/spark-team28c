#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
guard_edge
source "$(dirname "$0")/hive_env.sh"

fetch() { curl -fL --retry 3 --connect-timeout 20 -o "$2.part" "$1" && mv "$2.part" "$2"; }
mkdir -p "${DIST_DIR}"

log "=== Apache Spark ${SPARK_LINE}.x ==="
cur="$(readlink -f "${SPARK_DIR}" 2>/dev/null || true)"
if [ -n "${cur}" ] && [ -x "${SPARK_DIR}/bin/spark-submit" ]; then
  echo "уже установлен: ${cur}"
else
  ver="$(curl -s --connect-timeout 20 https://dlcdn.apache.org/spark/ | grep -oE "spark-${SPARK_LINE//./\\.}\.[0-9]+/" | tr -d '/' | sed 's/spark-//' | sort -V | tail -n 1 || true)"
  ver="${ver:-${SPARK_FALLBACK_VERSION}}"
  TGZ="spark-${ver}-bin-hadoop3.tgz"
  echo "версия: ${ver}"
  if [ ! -s "${DIST_DIR}/${TGZ}" ]; then
    for base in "https://dlcdn.apache.org/spark" "https://archive.apache.org/dist/spark"; do
      fetch "${base}/spark-${ver}/${TGZ}" "${DIST_DIR}/${TGZ}" && break
    done
  fi
  [ -s "${DIST_DIR}/${TGZ}" ] || die "не удалось скачать Spark"
  for base in "https://downloads.apache.org/spark" "https://archive.apache.org/dist/spark"; do
    if fetch "${base}/spark-${ver}/${TGZ}.sha512" "${DIST_DIR}/${TGZ}.sha512" 2>/dev/null; then
      want="$(tr -d ' \n' < "${DIST_DIR}/${TGZ}.sha512" | grep -oiE '[0-9a-f]{128}' | tr 'A-F' 'a-f' | sed -n 1p || true)"
      have="$(sha512sum "${DIST_DIR}/${TGZ}" | cut -d' ' -f1)"
      [ -z "${want}" ] || [ "${want}" = "${have}" ] || die "sha512 Spark не совпадает — удалите ${DIST_DIR}/${TGZ}"
      [ -n "${want}" ] && log "sha512 Spark OK"
      break
    fi
  done
  tar -xzf "${DIST_DIR}/${TGZ}" -C "${APPS_DIR}"
  ln -sfn "${APPS_DIR}/spark-${ver}-bin-hadoop3" "${SPARK_DIR}"
fi
"${SPARK_DIR}/bin/spark-submit" --version 2>&1 | grep -m1 -oE 'version [0-9.]+' || true

log "=== Конфигурация Spark ==="
cat > "${SPARK_DIR}/conf/spark-env.sh" <<EOF
export JAVA_HOME=${JAVA_DIR}
export HADOOP_CONF_DIR=${HADOOP_DIR}/etc/hadoop
export YARN_CONF_DIR=${HADOOP_DIR}/etc/hadoop
export PYSPARK_PYTHON=python3
export PYSPARK_DRIVER_PYTHON=python3
export SPARK_LOCAL_IP=${EDGE_IP}
EOF
cat > "${SPARK_DIR}/conf/spark-defaults.conf" <<EOF
spark.master                          yarn
spark.submit.deployMode               client
spark.driver.memory                   ${SPARK_DRIVER_MEM}
spark.driver.host                     ${EDGE_IP}
spark.driver.bindAddress              0.0.0.0
spark.driver.port                     ${PORT_SPARK_DRIVER}
spark.blockManager.port               ${PORT_SPARK_BM}
spark.ui.port                         ${PORT_SPARK_UI}
spark.port.maxRetries                 8
spark.yarn.am.memory                  ${SPARK_AM_MEM}
spark.executor.memory                 ${SPARK_EXECUTOR_MEM}
spark.executor.cores                  ${SPARK_EXECUTOR_CORES}
spark.executor.instances              ${SPARK_EXECUTORS}
spark.dynamicAllocation.enabled       false
spark.yarn.archive                    hdfs://${NN_HOST}:${PORT_NN_RPC}${SPARK_ARCHIVE}
spark.yarn.am.extraJavaOptions        -Djdk.net.hosts.file=${HOSTS_FILE}
spark.executor.extraJavaOptions       -Djdk.net.hosts.file=${HOSTS_FILE}
spark.eventLog.enabled                true
spark.eventLog.dir                    hdfs://${NN_HOST}:${PORT_NN_RPC}${SPARK_EVENTLOG}
spark.sql.catalogImplementation       hive
spark.sql.warehouse.dir               hdfs://${NN_HOST}:${PORT_NN_RPC}${HIVE_WAREHOUSE}
spark.sql.orc.impl                    native
spark.ui.showConsoleProgress          false
EOF
cat > "${SPARK_DIR}/conf/hive-site.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <property><name>hive.metastore.uris</name><value>thrift://${HIVE_HOST}:${PORT_HMS}</value></property>
  <property><name>hive.metastore.warehouse.dir</name><value>${HIVE_WAREHOUSE}</value></property>
  <property><name>hive.metastore.warehouse.external.dir</name><value>${HIVE_WAREHOUSE_EXT}</value></property>
</configuration>
EOF
if grep -RniE 'team28a|team28b' "${SPARK_DIR}/conf"; then die "в конфигах Spark найдены пути других команд"; fi
echo "${SPARK_DIR}/conf: spark-env.sh, spark-defaults.conf, hive-site.xml"

log "=== Библиотеки Spark в HDFS (spark.yarn.archive) ==="
hdfs dfs -mkdir -p "${SPARK_HDFS_DIR}" "${SPARK_EVENTLOG}"
if hdfs dfs -test -e "${SPARK_ARCHIVE}" && [ -f "${SPARK_DIR}/.archive_uploaded" ]; then
  echo "уже загружены"
else
  ZIP="${DIST_DIR}/spark-jars.zip"
  rm -f "${ZIP}"
  ( cd "${SPARK_DIR}/jars" && python3 -m zipfile -c "${ZIP}" ./*.jar )
  hdfs dfs -put -f "${ZIP}" "${SPARK_ARCHIVE}"
  touch "${SPARK_DIR}/.archive_uploaded"
fi
hdfs dfs -ls "${SPARK_ARCHIVE}"
log "Установка Spark завершена."
