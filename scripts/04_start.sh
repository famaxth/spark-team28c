#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
guard_edge

start_daemon() {
  local host="$1" cls="$2" name="$3"; shift 3
  local re; re="$(ports_regex "$@")"
  log "${host}: ${cls}"
  rsh "${host}" "$HENV
    if jps | grep -qw ${cls}; then echo '${cls} Team C уже запущен'; exit 0; fi
    if ss -ltn | grep -E '${re}'; then echo 'STOP: порт занят, ничего не трогаем' >&2; exit 1; fi
    hdfs --daemon start ${name}
    for i in \$(seq 1 30); do
      ss -ltn | grep -qE ':$1\\b' && { echo 'запущен, слушает порт $1'; jps | grep -w ${cls}; exit 0; }
      sleep 2
    done
    echo '${cls} не поднялся за 60с, хвост лога:' >&2
    tail -n 40 ${LOG_DIR}/hadoop-${TEAM_USER}-${name}-${host}.log >&2 || true
    exit 1"
}

start_daemon "${NN_HOST}" NameNode namenode "${PORT_NN_RPC}" "${PORT_NN_HTTP}"
for h in ${DN_HOSTS}; do
  start_daemon "${h}" DataNode datanode "${PORT_DN_DATA}" "${PORT_DN_HTTP}" "${PORT_DN_IPC}"
done
start_daemon "${SNN_HOST}" SecondaryNameNode secondarynamenode "${PORT_SNN_HTTP}"

log "Все демоны запущены. Дальше: scripts/05_verify.sh"
