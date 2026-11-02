#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
guard_edge
source "$(dirname "$0")/hive_env.sh"

for s in hiveserver2 metastore; do
  if svc_running "${s}"; then
    pid="$(cat "${HIVE_PID_DIR}/${s}.pid")"
    log "stop ${s} (pid ${pid})"
    kill "${pid}"
    for _ in $(seq 1 20); do kill -0 "${pid}" 2>/dev/null || break; sleep 1; done
  else
    echo "${s}: не запущен"
  fi
  rm -f "${HIVE_PID_DIR}/${s}.pid"
done
if pg_running; then
  log "stop PostgreSQL"
  "${PGBIN}/pg_ctl" -D "${PG_DATA}" -m fast -w stop
fi
