#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

log "=== Edge ==="
echo "whoami=$(whoami) hostname=$(hostname) pwd=$(pwd) HOME=${HOME}"
guard_edge
for f in authorized_keys team28c_internal team28c_internal.pub; do
  [ -e "${HOME}/.ssh/${f}" ] || die "нет ~/.ssh/${f}"
done
log "edge OK, ключи на месте"

RE="$(ports_regex ${TEAM_C_PORTS})"
for h in ${ALL_NODES}; do
  log "=== ${h} ==="
  out="$(rsh "${h}" 'echo "USER=$(whoami) HOST=$(hostname) HOME=$HOME"')" \
    || die "${h}: нет доступа по SSH или не прошла проверка user/host/home"
  echo "${out}"
  [ "${out}" = "USER=${TEAM_USER} HOST=${h} HOME=${TEAM_HOME}" ] || die "${h}: неожиданный результат"

  echo "--- getent hosts:"
  rsh "${h}" "getent hosts ${ALL_NODES}" || die "${h}: не резолвятся имена узлов"

  echo "--- порты Team C (${TEAM_C_PORTS}):"
  busy="$(rsh "${h}" "ss -ltnp 2>/dev/null | grep -E '${RE}' || true")"
  if [ -z "${busy}" ]; then
    echo "свободны"
  else
    echo "${busy}"
    mine="$(rsh "${h}" "jps -q 2>/dev/null || ${JAVA_DIR}/bin/jps -q 2>/dev/null || true")"
    foreign=0
    while read -r line; do
      [ -z "${line}" ] && continue
      pid="$(echo "${line}" | sed -nE 's/.*pid=([0-9]+).*/\1/p')"
      if [ -z "${pid}" ] || ! echo "${mine}" | grep -qx "${pid}"; then foreign=1; fi
    done <<< "${busy}"
    [ "${foreign}" = 0 ] || die "${h}: порт Team C занят ЧУЖИМ процессом. Ничего не останавливаем — выберите другой порт в config.env"
    warn "${h}: порты заняты процессами Team C (кластер уже запущен?)"
  fi

  echo "--- диск ${TEAM_HOME}:"
  rsh "${h}" "df -h ${TEAM_HOME} | tail -1"
done

log "Preflight пройден: доступ, имена, порты в порядке."
