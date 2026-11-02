#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
guard_edge

log "=== ${NN_HOST}: проверка перед format ==="
rsh "${NN_HOST}" "$HENV
  echo \"whoami=\$(whoami) hostname=\$(hostname) pwd=\$(pwd)\"
  dir=\$(hdfs getconf -confKey dfs.namenode.name.dir)
  echo \"dfs.namenode.name.dir = \$dir\"
  [ \"\$dir\" = 'file://${NN_DIR}' ] || { echo 'name.dir не Team C' >&2; exit 1; }
  if grep -RniE 'team28a|team28b' \$HADOOP_CONF_DIR; then echo 'чужие пути в конфиге' >&2; exit 1; fi
  if jps | grep -qw NameNode; then echo 'NameNode Team C уже запущен — format запрещён' >&2; exit 1; fi"

if rsh "${NN_HOST}" "[ -f ${NN_DIR}/current/VERSION ]"; then
  warn "NameNode Team C уже отформатирован (${NN_DIR}/current/VERSION). Повторный format НЕ выполняется."
  rsh "${NN_HOST}" "grep -E 'clusterID|namespaceID' ${NN_DIR}/current/VERSION"
  exit 0
fi

log "=== ${NN_HOST}: hdfs namenode -format ==="
rsh "${NN_HOST}" "$HENV
  hdfs namenode -format -nonInteractive -clusterid CID-team28c 2>&1 | tail -n 5
  grep -E 'clusterID|namespaceID' ${NN_DIR}/current/VERSION"
log "NameNode отформатирован."
