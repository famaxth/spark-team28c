#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
guard_edge
FAIL=0
CLIENT="${JHS_HOST}"
CENV="$HENV; export HADOOP_CLIENT_OPTS=-Xmx256m"

log "=== Демоны YARN ==="
st() {
  if rsh "$1" "$HENV; $2 --daemon status $3 2>&1 | grep -q 'is running'"; then echo "$1: $3 работает"
  else warn "$1: $3 НЕ работает"; FAIL=1; fi
}
st "${RM_HOST}" yarn resourcemanager
for h in ${NM_HOSTS}; do st "${h}" yarn nodemanager; done
st "${JHS_HOST}" mapred historyserver

log "=== Узлы YARN ==="
want="$(echo ${NM_HOSTS} | wc -w)"
rsh "${CLIENT}" "$CENV
  for i in \$(seq 1 30); do
    n=\$(yarn node -list 2>/dev/null | grep -c RUNNING || true)
    [ \"\$n\" -ge ${want} ] && break; sleep 2
  done
  yarn node -list -all 2>/dev/null
  [ \"\$n\" -ge ${want} ]" || { warn "RUNNING NodeManager меньше ${want}"; FAIL=1; }

log "=== ResourceManager REST (http://${RM_HOST}:${PORT_RM_HTTP}) ==="
info="$(rsh "${CLIENT}" "curl -sf http://${RM_HOST}:${PORT_RM_HTTP}/ws/v1/cluster/info" || true)"
echo "${info}" | grep -oE '"(state|haState|hadoopVersion)":"[^"]*"' | tr '\n' ' '; echo
echo "${info}" | grep -q '"state":"STARTED"' || { warn "RM не в состоянии STARTED"; FAIL=1; }

log "=== Тестовая задача MapReduce (pi) ==="
out="$(rsh "${CLIENT}" "$CENV
  timeout 600 yarn jar ${HADOOP_DIR}/share/hadoop/mapreduce/hadoop-mapreduce-examples-${HADOOP_VERSION}.jar pi 2 10 2>&1 | grep -E 'Running job|Job job_|Job Finished|Estimated value of Pi|ERROR|Exception' || true" || true)"
echo "${out}"
echo "${out}" | grep -q 'Estimated value of Pi' || { warn "задача pi не выполнилась"; FAIL=1; }
job="$(echo "${out}" | grep -oE 'job_[0-9]+_[0-9]+' | tail -n 1 || true)"

log "=== JobHistoryServer (http://${JHS_HOST}:${PORT_JHS_HTTP}) ==="
if [ -n "${job}" ]; then
  ok=no
  for _ in $(seq 1 20); do
    js="$(rsh "${CLIENT}" "curl -sf http://${JHS_HOST}:${PORT_JHS_HTTP}/ws/v1/history/mapreduce/jobs/${job}" || true)"
    if echo "${js}" | grep -q '"state":"SUCCEEDED"'; then ok=yes; break; fi
    sleep 3
  done
  [ "${ok}" = yes ] && echo "${job}: SUCCEEDED в истории" || { warn "${job} не найден в JobHistory"; FAIL=1; }
fi

log "=== Логи YARN: FATAL / ERROR ==="
for h in $(echo ${RM_HOST} ${NM_HOSTS} ${JHS_HOST} | tr ' ' '\n' | sort -u); do
  o="$(rsh "${h}" "grep -hE ' (FATAL|ERROR) ' ${LOG_DIR}/hadoop-${TEAM_USER}-{resourcemanager,nodemanager,historyserver}-*.log 2>/dev/null | grep -v 'RECEIVED SIGNAL' | tail -n 5 || true")"
  if [ -z "${o}" ]; then echo "${h}: критических ошибок нет"; else warn "${h}:"; echo "${o}"; FAIL=1; fi
done

log "=== Веб-интерфейсы через nginx на edge ==="
while IFS=: read -r pub _ _ name; do
  [ -z "${pub}" ] && continue
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "http://127.0.0.1:${pub}/" || true)"
  printf '%-24s http://%s:%s/  HTTP %s\n' "${name}" "${PUBLIC_HOST}" "${pub}" "${code}"
  case "${code}" in 200|301|302|303|307) ;; *) FAIL=1;; esac
done <<< "${WEB_MAP}"

echo
if [ "${FAIL}" = 0 ]; then
  log "YARN TEAM C РАБОТАЕТ: ResourceManager + $(echo ${NM_HOSTS} | wc -w) NodeManager + JobHistoryServer, веб-интерфейсы опубликованы."
  echo "Доступ с ноутбука через SSH-туннель:"
  echo "  $(tunnel_cmd)"
  echo "Затем откройте http://${PUBLIC_HOST}:${WEB_INDEX_PORT}/"
else
  die "Есть проблемы — см. вывод выше."
fi
