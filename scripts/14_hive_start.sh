#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
guard_edge
source "$(dirname "$0")/hive_env.sh"
mkdir -p "${HIVE_LOG_DIR}" "${HIVE_PID_DIR}"

avail="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)"
echo "edge: свободно памяти ${avail} МБ"

pg_running || "${PGBIN}/pg_ctl" -D "${PG_DATA}" -l "${HIVE_LOG_DIR}/postgres.log" -w -t 60 start >/dev/null
pg_running || die "PostgreSQL не запущен"
echo "PostgreSQL работает (127.0.0.1:${PORT_PG})"

start_svc() {
  local name="$1" port="$2" heap="$3" wait_s="$4"
  log "${HIVE_HOST}: ${name}"
  if svc_running "${name}"; then echo "${name} Team C уже запущен (pid $(cat "${HIVE_PID_DIR}/${name}.pid"))"; return 0; fi
  check_hive_port "${port}" no
  [ "${avail}" -ge $((heap + 200)) ] || die "мало памяти на edge для ${name}"
  HADOOP_CLIENT_OPTS="-Xmx${heap}m" setsid nohup hive --service "${name}" \
    > "${HIVE_LOG_DIR}/${name}.out" 2>&1 < /dev/null &
  echo $! > "${HIVE_PID_DIR}/${name}.pid"
  for _ in $(seq 1 $((wait_s / 3))); do
    if ss -ltn | grep -qE ":${port}\b"; then echo "запущен (pid $(cat "${HIVE_PID_DIR}/${name}.pid")), слушает порт ${port}"; return 0; fi
    kill -0 "$(cat "${HIVE_PID_DIR}/${name}.pid")" 2>/dev/null || break
    sleep 3
  done
  echo "${name} не поднялся, хвост лога:" >&2
  tail -n 40 "${HIVE_LOG_DIR}/${name}.out" >&2 || true
  exit 1
}

start_svc metastore   "${PORT_HMS}" "${HMS_HEAP_MB}" 120
start_svc hiveserver2 "${PORT_HS2}" "${HS2_HEAP_MB}" 240

log "Hive запущен: Metastore thrift://${HIVE_HOST}:${PORT_HMS}, HiveServer2 ${HS2_URL}"
