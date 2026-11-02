#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
guard_edge
FAIL=0

log "=== Ожидание регистрации ${DFS_REPLICATION} DataNode ==="
rsh "${NN_HOST}" "$HENV
  for i in \$(seq 1 30); do
    n=\$(hdfs dfsadmin -report -live 2>/dev/null | sed -nE 's/^Live datanodes \(([0-9]+)\):.*/\1/p' || true)
    [ \"\${n:-0}\" -ge 3 ] && { echo \"Live datanodes: \$n\"; exit 0; }
    sleep 2
  done
  echo \"Live datanodes: \${n:-0} (ожидалось 3)\" >&2; exit 1" || FAIL=1

log "=== hdfs dfsadmin -report ==="
rsh "${NN_HOST}" "$HENV
  hdfs dfsadmin -safemode wait
  hdfs dfsadmin -report | grep -E '^(Configured Capacity|DFS Used|Live datanodes|Dead datanodes|Name:|Hostname:|Decommission Status)'" || FAIL=1

log "=== NameNode Web UI / JMX (http://${NN_HOST}:${PORT_NN_HTTP}) ==="
jmx="$(rsh "${NN_HOST}" "curl -sf 'http://${NN_HOST}:${PORT_NN_HTTP}/jmx?qry=Hadoop:service=NameNode,name=FSNamesystemState'")" \
  || { warn "JMX недоступен"; FAIL=1; jmx=""; }
get() { echo "${jmx}" | grep -oE "\"$1\" *: *[0-9]+" | grep -oE '[0-9]+$'; }
live="$(get NumLiveDataNodes)"; dead="$(get NumDeadDataNodes)"; stale="$(get NumStaleDataNodes)"
echo "NumLiveDataNodes=${live:-?} NumDeadDataNodes=${dead:-?} NumStaleDataNodes=${stale:-?}"
[ "${live:-0}" = 3 ] && [ "${dead:-1}" = 0 ] && [ "${stale:-1}" = 0 ] || { warn "в Web UI не 3 здоровых DataNode"; FAIL=1; }

log "=== hdfs fsck / ==="
fsck="$(rsh "${NN_HOST}" "$HENV; hdfs fsck / 2>/dev/null | tail -n 12" || true)"
echo "${fsck}"
echo "${fsck}" | grep -q 'is HEALTHY' || FAIL=1

log "=== Тест записи/чтения ==="
rsh "${NN_HOST}" "$HENV
  f=${PID_DIR}/smoke-\$\$.txt; echo \"team28c smoke \$(date)\" > \$f
  hdfs dfs -mkdir -p /user/${TEAM_USER}/smoke
  hdfs dfs -put -f \$f /user/${TEAM_USER}/smoke/test.txt
  hdfs dfs -cat /user/${TEAM_USER}/smoke/test.txt | cmp - \$f && echo 'read == write: OK'
  hdfs fsck /user/${TEAM_USER}/smoke/test.txt -files -blocks -locations 2>/dev/null | grep -E 'repl=|Average block replication'
  hdfs dfs -rm -r -skipTrash /user/${TEAM_USER}/smoke >/dev/null; rm -f \$f" || FAIL=1

log "=== Логи: FATAL / ERROR ==="
for h in ${ALL_NODES}; do
  out="$(rsh "${h}" "grep -hE ' (FATAL|ERROR) ' ${LOG_DIR}/*.log 2>/dev/null | grep -v 'RECEIVED SIGNAL' | tail -n 5 || true")"
  if [ -z "${out}" ]; then echo "${h}: критических ошибок нет"; else warn "${h}:"; echo "${out}"; FAIL=1; fi
  rsh "${h}" "$HENV; jps | grep -vw Jps | sed 's/^/  /'"
done

echo
if [ "${FAIL}" = 0 ]; then log "КЛАСТЕР TEAM C ЦЕЛОСТНЫЙ: NameNode + SecondaryNameNode + 3 DataNode, ошибок нет."
else die "Есть проблемы — см. вывод выше."; fi
