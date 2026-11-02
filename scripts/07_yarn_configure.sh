#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
guard_edge

BUILD="${REPO_DIR}/build-yarn"
rm -rf "${BUILD}"; mkdir -p "${BUILD}"

prop() { printf '  <property>\n    <name>%s</name>\n    <value>%s</value>\n  </property>\n' "$1" "$2"; }
xml_head() { printf '<?xml version="1.0" encoding="UTF-8"?>\n<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>\n<configuration>\n'; }

gen_yarn() {
  local host="$1"
  xml_head
  prop yarn.resourcemanager.hostname                 "${RM_HOST}"
  prop yarn.resourcemanager.bind-host                "0.0.0.0"
  prop yarn.resourcemanager.address                  "${RM_HOST}:${PORT_RM_RPC}"
  prop yarn.resourcemanager.scheduler.address        "${RM_HOST}:${PORT_RM_SCHED}"
  prop yarn.resourcemanager.resource-tracker.address "${RM_HOST}:${PORT_RM_TRACKER}"
  prop yarn.resourcemanager.admin.address            "${RM_HOST}:${PORT_RM_ADMIN}"
  prop yarn.resourcemanager.webapp.address           "${RM_HOST}:${PORT_RM_HTTP}"
  prop yarn.resourcemanager.webapp.https.address     "${RM_HOST}:${PORT_RM_HTTPS}"
  prop yarn.resourcemanager.scheduler.class          "org.apache.hadoop.yarn.server.resourcemanager.scheduler.capacity.CapacityScheduler"
  prop yarn.nodemanager.hostname                     "${host}"
  prop yarn.nodemanager.bind-host                    "0.0.0.0"
  prop yarn.nodemanager.address                      "${host}:${PORT_NM_RPC}"
  prop yarn.nodemanager.localizer.address            "${host}:${PORT_NM_LOCALIZER}"
  prop yarn.nodemanager.webapp.address               "${host}:${PORT_NM_HTTP}"
  prop yarn.nodemanager.webapp.https.address         "${host}:${PORT_NM_HTTPS}"
  prop yarn.nodemanager.local-dirs                   "${NM_LOCAL_DIR}"
  prop yarn.nodemanager.log-dirs                     "${NM_LOG_DIR}"
  prop yarn.nodemanager.resource.memory-mb           "${NM_MEMORY_MB}"
  prop yarn.nodemanager.resource.cpu-vcores          "${NM_VCORES}"
  prop yarn.scheduler.minimum-allocation-mb          "${CONTAINER_MIN_MB}"
  prop yarn.scheduler.maximum-allocation-mb          "${CONTAINER_MAX_MB}"
  prop yarn.nodemanager.vmem-check-enabled           "false"
  prop yarn.nodemanager.aux-services                 "mapreduce_shuffle"
  prop yarn.nodemanager.aux-services.mapreduce_shuffle.class "org.apache.hadoop.mapred.ShuffleHandler"
  prop yarn.nodemanager.env-whitelist                "JAVA_HOME,HADOOP_COMMON_HOME,HADOOP_HDFS_HOME,HADOOP_CONF_DIR,CLASSPATH_PREPEND_DISTCACHE,HADOOP_YARN_HOME,HADOOP_HOME,PATH,LANG,TZ,HADOOP_MAPRED_HOME"
  prop yarn.log-aggregation-enable                   "true"
  prop yarn.nodemanager.remote-app-log-dir           "/tmp/logs"
  prop yarn.log.server.url                           "http://${JHS_HOST}:${PORT_JHS_HTTP}/jobhistory/logs"
  echo '</configuration>'
}

gen_mapred() {
  xml_head
  prop mapreduce.framework.name                 "yarn"
  prop mapreduce.jobhistory.address             "${JHS_HOST}:${PORT_JHS_RPC}"
  prop mapreduce.jobhistory.admin.address       "${JHS_HOST}:${PORT_JHS_ADMIN}"
  prop mapreduce.jobhistory.webapp.address      "${JHS_HOST}:${PORT_JHS_HTTP}"
  prop mapreduce.jobhistory.webapp.https.address "${JHS_HOST}:${PORT_JHS_HTTPS}"
  prop mapreduce.jobhistory.bind-host           "0.0.0.0"
  prop mapreduce.shuffle.port                   "${PORT_SHUFFLE}"
  prop yarn.app.mapreduce.am.env                "HADOOP_MAPRED_HOME=${HADOOP_DIR}"
  prop mapreduce.map.env                        "HADOOP_MAPRED_HOME=${HADOOP_DIR}"
  prop mapreduce.reduce.env                     "HADOOP_MAPRED_HOME=${HADOOP_DIR}"
  prop mapreduce.application.classpath          "${HADOOP_DIR}/share/hadoop/mapreduce/*:${HADOOP_DIR}/share/hadoop/mapreduce/lib/*"
  prop yarn.app.mapreduce.am.resource.mb        "${MR_AM_MB}"
  prop yarn.app.mapreduce.am.command-opts       "${MR_JAVA_OPTS}"
  prop mapreduce.map.memory.mb                  "${MR_MAP_MB}"
  prop mapreduce.map.java.opts                  "${MR_JAVA_OPTS}"
  prop mapreduce.reduce.memory.mb               "${MR_REDUCE_MB}"
  prop mapreduce.reduce.java.opts               "${MR_JAVA_OPTS}"
  echo '</configuration>'
}

gen_capacity() {
  xml_head
  prop yarn.scheduler.capacity.maximum-applications              "1000"
  prop yarn.scheduler.capacity.maximum-am-resource-percent       "0.5"
  prop yarn.scheduler.capacity.resource-calculator               "org.apache.hadoop.yarn.util.resource.DefaultResourceCalculator"
  prop yarn.scheduler.capacity.root.queues                       "default"
  prop yarn.scheduler.capacity.root.default.capacity             "100"
  prop yarn.scheduler.capacity.root.default.maximum-capacity     "100"
  prop yarn.scheduler.capacity.root.default.user-limit-factor    "1"
  prop yarn.scheduler.capacity.root.default.state                "RUNNING"
  echo '</configuration>'
}

{
  echo "127.0.0.1 localhost"
  while read -r ip name; do
    [ -z "${ip}" ] && continue
    echo "${ip} ${name} ${name}.${DNS_DOMAIN}"
  done <<< "${HOSTS_ENTRIES}"
} > "${BUILD}/hosts.team28c"
mkdir -p "$(dirname "${HOSTS_FILE}")"
cp "${BUILD}/hosts.team28c" "${HOSTS_FILE}"

for h in ${ALL_NODES}; do
  d="${BUILD}/${h}"; mkdir -p "${d}"
  gen_yarn "${h}" > "${d}/yarn-site.xml"
  gen_mapred      > "${d}/mapred-site.xml"
  gen_capacity    > "${d}/capacity-scheduler.xml"
done

if grep -RniE 'team28a|team28b' "${BUILD}"; then die "в конфигах найдены пути других команд"; fi
if grep -RnE ":($(echo ${FOREIGN_PORTS} ${FOREIGN_YARN_PORTS} | tr ' ' '|'))<" "${BUILD}"; then die "в конфигах найдены чужие порты"; fi
log "YARN-конфиги сгенерированы в ${BUILD}"

CONF="${HADOOP_DIR}/etc/hadoop"
for h in ${ALL_NODES}; do
  log "=== ${h}: раскатка YARN-конфигов ==="
  rsh "${h}" "[ -d ${CONF} ] || { echo 'Hadoop не установлен' >&2; exit 1; }
    mkdir -p ${NM_LOCAL_DIR} ${NM_LOG_DIR} ${LOG_DIR} ${PID_DIR} $(dirname "${HOSTS_FILE}")"
  rcopy "${BUILD}/hosts.team28c" "${h}" "${HOSTS_FILE}"
  rcopy "${BUILD}/${h}/yarn-site.xml"   "${h}" "${CONF}/yarn-site.xml"
  rcopy "${BUILD}/${h}/mapred-site.xml" "${h}" "${CONF}/mapred-site.xml"
  rcopy "${BUILD}/${h}/capacity-scheduler.xml" "${h}" "${CONF}/capacity-scheduler.xml"
  rsh "${h}" "$HENV
    if grep -RniE 'team28a|team28b' ${CONF}; then echo 'найдены чужие пути' >&2; exit 1; fi
    grep -A1 -E '<name>(yarn.resourcemanager.webapp.address|yarn.nodemanager.hostname|mapreduce.jobhistory.webapp.address)<' ${CONF}/yarn-site.xml ${CONF}/mapred-site.xml | sed -nE 's#.*<(name|value)>(.*)</(name|value)>.*#  \\2#p' | paste - -"
done
log "Конфигурация YARN завершена."
