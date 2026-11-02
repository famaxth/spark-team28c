#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_DIR}/config.env"

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_rst=$'\e[0m'
log()  { echo "${c_grn}[$(date +%H:%M:%S)] $*${c_rst}"; }
warn() { echo "${c_ylw}[WARN] $*${c_rst}" >&2; }
die()  { echo "${c_red}[STOP] $*${c_rst}" >&2; exit 1; }

guard_edge() {
  [ "$(id -un)" = "${TEAM_USER}" ] || die "whoami=$(id -un), ожидается ${TEAM_USER}"
  [ "${HOME}" = "${TEAM_HOME}" ]   || die "HOME=${HOME}, ожидается ${TEAM_HOME}"
  [ "$(hostname -s)" = "${EDGE_HOST}" ] || die "hostname=$(hostname -s), ожидается ${EDGE_HOST}"
  case "${REPO_DIR}" in "${TEAM_HOME}"/*) ;; *) die "репозиторий должен лежать внутри ${TEAM_HOME}";; esac
  [ -f "${SSH_KEY}" ] || die "нет ключа ${SSH_KEY}"
}

SSH_OPTS=(-i "${SSH_KEY}" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

export HENV="export JAVA_HOME=${JAVA_DIR} HADOOP_HOME=${HADOOP_DIR} HADOOP_CONF_DIR=${HADOOP_DIR}/etc/hadoop HADOOP_LOG_DIR=${LOG_DIR} HADOOP_PID_DIR=${PID_DIR}; export PATH=${JAVA_DIR}/bin:${HADOOP_DIR}/bin:\$PATH"

rsh() {
  local host="$1"; shift
  local guard="set -euo pipefail
[ \"\$(id -un)\" = '${TEAM_USER}' ] || { echo 'GUARD: wrong user' >&2; exit 90; }
[ \"\$HOME\" = '${TEAM_HOME}' ]     || { echo 'GUARD: wrong HOME' >&2; exit 91; }
[ \"\$(hostname -s)\" = '${host}' ] || { echo \"GUARD: wrong host \$(hostname -s)\" >&2; exit 92; }
cd '${TEAM_HOME}'"
  ssh "${SSH_OPTS[@]}" "${TEAM_USER}@${host}" "bash -c $(printf '%q' "${guard}
$*")"
}

rcopy() {
  local src="$1" host="$2" dst="$3"
  case "${dst}" in "${TEAM_HOME}"/*) ;; *) die "rcopy: путь ${dst} вне ${TEAM_HOME}";; esac
  scp -q "${SSH_OPTS[@]}" -r "${src}" "${TEAM_USER}@${host}:${dst}"
}

ports_regex() { echo ":($(echo "$*" | tr ' ' '|'))\\b"; }

tunnel_cmd() {
  local args="-L ${WEB_INDEX_PORT}:127.0.0.1:${WEB_INDEX_PORT}" pub
  while IFS=: read -r pub _ _ _; do
    [ -z "${pub}" ] && continue
    args="${args} -L ${pub}:127.0.0.1:${pub}"
  done <<< "${WEB_MAP}"
  echo "ssh -N ${args} ${TEAM_USER}@${EDGE_PUBLIC_IP}"
}
