#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
guard_edge

check_mem() {
  local host="$1" need="$2" avail
  avail="$(rsh "${host}" "awk '/MemAvailable/{print int(\$2/1024)}' /proc/meminfo")"
  echo "${host}: свободно памяти ${avail} МБ (нужно не меньше ${need} МБ)"
  [ "${avail}" -ge "${need}" ] || die "${host}: мало памяти — запуск может задеть процессы других команд"
}

start_daemon() {
  local host="$1" bin="$2" cls="$3" name="$4"; shift 4
  local re; re="$(ports_regex "$@")"
  log "${host}: ${cls}"
  rsh "${host}" "$HENV
    if ${bin} --daemon status ${name} 2>&1 | grep -q 'is running'; then echo '${cls} Team C уже запущен'; exit 0; fi
    if ss -ltn | grep -E '${re}'; then echo 'STOP: порт занят, ничего не трогаем' >&2; exit 1; fi
    ${bin} --daemon start ${name}
    for i in \$(seq 1 45); do
      ss -ltn | grep -qE ':$1\\b' && { echo 'запущен, слушает порт $1'; jps | grep -w ${cls}; exit 0; }
      sleep 2
    done
    echo '${cls} не поднялся за 90с, хвост лога:' >&2
    tail -n 40 ${LOG_DIR}/hadoop-${TEAM_USER}-${name}-\$(hostname).log >&2 || true
    exit 1"
}

log "=== SecondaryNameNode: публикация на 0.0.0.0:${PORT_SNN_HTTP} ==="
rsh "${SNN_HOST}" "$HENV
  if ss -ltn | grep -qE '127\\.0\\.[01]\\.1:${PORT_SNN_HTTP}\\b'; then
    hdfs --daemon stop secondarynamenode
    sleep 3
    hdfs --daemon start secondarynamenode
    for i in \$(seq 1 30); do ss -ltn | grep -qE '0\\.0\\.0\\.0:${PORT_SNN_HTTP}\\b' && break; sleep 2; done
  fi
  ss -ltn | grep -E ':${PORT_SNN_HTTP}\\b'"

log "=== HDFS-каталоги для YARN/MapReduce ==="
rsh "${NN_HOST}" "$HENV
  hdfs dfsadmin -safemode wait >/dev/null
  hdfs dfs -mkdir -p /tmp /tmp/logs /tmp/hadoop-yarn/staging /user/${TEAM_USER}
  hdfs dfs -chmod 1777 /tmp /tmp/logs /tmp/hadoop-yarn/staging
  hdfs dfs -ls /tmp"

log "=== Проверка памяти ==="
check_mem "${RM_HOST}" 800
for h in ${NM_HOSTS}; do check_mem "${h}" 600; done
check_mem "${JHS_HOST}" 500

start_daemon "${RM_HOST}" yarn ResourceManager resourcemanager \
  "${PORT_RM_HTTP}" "${PORT_RM_SCHED}" "${PORT_RM_TRACKER}" "${PORT_RM_RPC}" "${PORT_RM_ADMIN}"
for h in ${NM_HOSTS}; do
  start_daemon "${h}" yarn NodeManager nodemanager \
    "${PORT_NM_HTTP}" "${PORT_NM_RPC}" "${PORT_NM_LOCALIZER}" "${PORT_SHUFFLE}"
done
start_daemon "${JHS_HOST}" mapred JobHistoryServer historyserver \
  "${PORT_JHS_HTTP}" "${PORT_JHS_RPC}" "${PORT_JHS_ADMIN}"

log "YARN запущен."
