#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
guard_edge

if [ -f "${NGINX_DIR}/run/nginx.pid" ]; then
  log "edge: stop nginx"
  "${NGINX_APP_DIR}/usr/sbin/nginx" -p "${NGINX_DIR}" -c "${NGINX_DIR}/conf/nginx.conf" -e "${NGINX_DIR}/logs/error.log" -s stop || true
fi
log "${JHS_HOST}: stop historyserver"
rsh "${JHS_HOST}" "$HENV; mapred --daemon stop historyserver || true"
for h in ${NM_HOSTS}; do
  log "${h}: stop nodemanager"
  rsh "${h}" "$HENV; yarn --daemon stop nodemanager || true"
done
log "${RM_HOST}: stop resourcemanager"
rsh "${RM_HOST}" "$HENV; yarn --daemon stop resourcemanager || true"
