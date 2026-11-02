#!/usr/bin/env bash
export JAVA_HOME="${JAVA_DIR}"
export HADOOP_HOME="${HADOOP_DIR}"
export HADOOP_CONF_DIR="${HADOOP_DIR}/etc/hadoop"
export HADOOP_LOG_DIR="${LOG_DIR}"
export HADOOP_PID_DIR="${PID_DIR}"
export HIVE_HOME="${HIVE_DIR}"
export HIVE_CONF_DIR="${HIVE_DIR}/conf"
export PATH="${JAVA_DIR}/bin:${HADOOP_DIR}/bin:${HIVE_DIR}/bin:${PATH}"
export LD_LIBRARY_PATH="${PG_APP_DIR}/usr/lib/x86_64-linux-gnu"
PGBIN="${PG_APP_DIR}/usr/lib/postgresql/${PG_MAJOR}/bin"
HS2_URL="jdbc:hive2://${HIVE_HOST}:${PORT_HS2}/default"

svc_running() {
  local pid
  pid="$(cat "${HIVE_PID_DIR}/$1.pid" 2>/dev/null)" || return 1
  [ -n "${pid}" ] || return 1
  ps -o args= -p "${pid}" 2>/dev/null | grep -q -- "-Dproc_$1"
}
pg_running() { "${PGBIN}/pg_ctl" -D "${PG_DATA}" status >/dev/null 2>&1; }

check_hive_port() {
  local port="$1" owner_ok="$2"
  if ss -ltn | grep -qE ":${port}\b"; then
    [ "${owner_ok}" = yes ] && { echo "порт ${port}: занят сервисом Team C"; return 0; }
    ss -ltn | grep -E ":${port}\b"
    die "порт ${port} занят чужим процессом — ничего не трогаем, выберите другой в config.env"
  fi
  echo "порт ${port}: свободен"
}

bl() { HADOOP_CLIENT_OPTS="-Xmx256m" beeline -u "${HS2_URL}" -n "${TEAM_USER}" --silent=true --showHeader=true --outputformat=table "$@"; }
