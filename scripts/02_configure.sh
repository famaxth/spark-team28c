#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
guard_edge

BUILD="${REPO_DIR}/build"
rm -rf "${BUILD}"; mkdir -p "${BUILD}"

prop() { printf '  <property>\n    <name>%s</name>\n    <value>%s</value>\n  </property>\n' "$1" "$2"; }
xml_head() { printf '<?xml version="1.0" encoding="UTF-8"?>\n<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>\n<configuration>\n'; }

gen_core() {
  xml_head
  prop fs.defaultFS          "hdfs://${NN_HOST}:${PORT_NN_RPC}"
  prop hadoop.tmp.dir        "${TMP_DIR}"
  echo '</configuration>'
}

gen_hdfs() {
  local host="$1"
  xml_head
  prop dfs.replication                         "${DFS_REPLICATION}"
  prop dfs.namenode.name.dir                   "file://${NN_DIR}"
  prop dfs.datanode.data.dir                   "file://${DN_DIR}"
  prop dfs.namenode.checkpoint.dir             "file://${SNN_DIR}"
  prop dfs.namenode.rpc-address                "${NN_HOST}:${PORT_NN_RPC}"
  prop dfs.namenode.rpc-bind-host              "0.0.0.0"
  prop dfs.namenode.servicerpc-bind-host       "0.0.0.0"
  prop dfs.namenode.http-address               "${NN_HOST}:${PORT_NN_HTTP}"
  prop dfs.namenode.http-bind-host             "0.0.0.0"
  prop dfs.namenode.https-address              "${NN_HOST}:${PORT_NN_HTTPS}"
  prop dfs.namenode.https-bind-host            "0.0.0.0"
  prop dfs.namenode.datanode.registration.ip-hostname-check "false"
  prop dfs.namenode.secondary.http-address     "0.0.0.0:${PORT_SNN_HTTP}"
  prop dfs.namenode.secondary.https-address    "0.0.0.0:${PORT_SNN_HTTPS}"
  prop dfs.datanode.hostname                   "${host}"
  prop dfs.datanode.address                    "0.0.0.0:${PORT_DN_DATA}"
  prop dfs.datanode.http.address               "0.0.0.0:${PORT_DN_HTTP}"
  prop dfs.datanode.https.address              "0.0.0.0:${PORT_DN_HTTPS}"
  prop dfs.datanode.ipc.address                "0.0.0.0:${PORT_DN_IPC}"
  prop dfs.client.use.datanode.hostname        "true"
  prop dfs.datanode.use.datanode.hostname      "true"
  prop dfs.permissions.superusergroup          "${TEAM_USER}"
  echo '</configuration>'
}

gen_env() {
  cat <<EOF
export JAVA_HOME=${JAVA_DIR}
export HADOOP_HOME=${HADOOP_DIR}
export HADOOP_CONF_DIR=${HADOOP_DIR}/etc/hadoop
export HADOOP_LOG_DIR=${LOG_DIR}
export HADOOP_PID_DIR=${PID_DIR}
export HADOOP_IDENT_STRING=${TEAM_USER}
export HADOOP_HEAPSIZE_MAX=1g
export YARN_RESOURCEMANAGER_HEAPSIZE=${RM_HEAP_MB}
export YARN_NODEMANAGER_HEAPSIZE=${NM_HEAP_MB}
export HADOOP_JOB_HISTORYSERVER_HEAPSIZE=${JHS_HEAP_MB}
EOF
}

gen_profile() {
  cat <<EOF
export JAVA_HOME=${JAVA_DIR}
export HADOOP_HOME=${HADOOP_DIR}
export HADOOP_CONF_DIR=${HADOOP_DIR}/etc/hadoop
export HADOOP_LOG_DIR=${LOG_DIR}
export HADOOP_PID_DIR=${PID_DIR}
export PATH=${JAVA_DIR}/bin:${HADOOP_DIR}/bin:${HADOOP_DIR}/sbin:\$PATH
EOF
}

for h in ${ALL_NODES}; do
  d="${BUILD}/${h}"; mkdir -p "${d}"
  gen_core      > "${d}/core-site.xml"
  gen_hdfs "${h}" > "${d}/hdfs-site.xml"
  gen_env       > "${d}/hadoop-env.sh"
  printf '%s\n' ${DN_HOSTS} > "${d}/workers"
  gen_profile   > "${d}/hadoop_team28c.sh"
done

if grep -RniE 'team28a|team28b' "${BUILD}"; then die "в конфигах найдены пути других команд"; fi
if grep -RnE ":($(echo ${FOREIGN_PORTS} | tr ' ' '|'))<" "${BUILD}"; then die "в конфигах найдены порты Team A/B"; fi
log "Конфиги сгенерированы в ${BUILD}"

CONF="${HADOOP_DIR}/etc/hadoop"
for h in ${ALL_NODES}; do
  log "=== ${h}: раскатка конфигов ==="
  rsh "${h}" "[ -d ${CONF} ] || { echo 'Hadoop не установлен — сначала 01_install.sh' >&2; exit 1; }
    [ -f ${CONF}/hadoop-env.sh.orig ] || cp ${CONF}/hadoop-env.sh ${CONF}/hadoop-env.sh.orig
    mkdir -p ${DN_DIR} ${TMP_DIR} ${LOG_DIR} ${PID_DIR}
    chmod 700 ${DN_DIR}"
  [ "${h}" = "${NN_HOST}" ]  && rsh "${h}" "mkdir -p ${NN_DIR} && chmod 700 ${NN_DIR}"
  [ "${h}" = "${SNN_HOST}" ] && rsh "${h}" "mkdir -p ${SNN_DIR} && chmod 700 ${SNN_DIR}"
  for f in core-site.xml hdfs-site.xml hadoop-env.sh workers; do
    rcopy "${BUILD}/${h}/${f}" "${h}" "${CONF}/${f}"
  done
  rcopy "${BUILD}/${h}/hadoop_team28c.sh" "${h}" "${TEAM_HOME}/.hadoop_team28c.sh"
  rsh "${h}" "grep -q '.hadoop_team28c.sh' ~/.bashrc 2>/dev/null || echo '[ -f ~/.hadoop_team28c.sh ] && . ~/.hadoop_team28c.sh' >> ~/.bashrc
    if grep -RniE 'team28a|team28b' ${CONF}; then echo 'найдены чужие пути' >&2; exit 1; fi
    echo \"fs.defaultFS = \$(JAVA_HOME=${JAVA_DIR} ${HADOOP_DIR}/bin/hdfs getconf -confKey fs.defaultFS)\"
    echo \"datanode.hostname = \$(JAVA_HOME=${JAVA_DIR} ${HADOOP_DIR}/bin/hdfs getconf -confKey dfs.datanode.hostname)\""
done
log "Конфигурация завершена."
