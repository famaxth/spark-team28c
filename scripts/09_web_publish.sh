#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
guard_edge

NGX_BIN="${NGINX_APP_DIR}/usr/sbin/nginx"
NGX_CONF="${NGINX_DIR}/conf/nginx.conf"
NGX=("${NGX_BIN}" -p "${NGINX_DIR}" -c "${NGX_CONF}" -e "${NGINX_DIR}/logs/error.log")

if [ ! -x "${NGX_BIN}" ]; then
  log "Скачиваю nginx (без sudo, распаковка в ${NGINX_APP_DIR})"
  mkdir -p "${DIST_DIR}/nginx" "${NGINX_APP_DIR}"
  ( cd "${DIST_DIR}/nginx" && apt-get download nginx nginx-common >/dev/null )
  for deb in "${DIST_DIR}"/nginx/nginx*.deb; do dpkg -x "${deb}" "${NGINX_APP_DIR}"; done
fi
[ -x "${NGX_BIN}" ] || die "nginx не установлен"
"${NGX_BIN}" -V 2>&1 | grep -q http_sub_module || die "в этой сборке nginx нет http_sub_module"
"${NGX_BIN}" -v 2>&1

mkdir -p "${NGINX_DIR}"/{conf,logs,run,www} "${NGINX_DIR}"/tmp/{body,proxy,fastcgi,uwsgi,scgi}

running=no
if [ -f "${NGINX_DIR}/run/nginx.pid" ] && kill -0 "$(cat "${NGINX_DIR}/run/nginx.pid")" 2>/dev/null; then running=yes; fi

PUB_PORTS="${WEB_INDEX_PORT} $(echo "${WEB_MAP}" | cut -d: -f1 | tr '\n' ' ')"
if [ "${running}" = no ]; then
  busy="$(ss -ltn | grep -E "$(ports_regex ${PUB_PORTS})" || true)"
  [ -z "${busy}" ] || { echo "${busy}"; die "на edge заняты порты публикации — выберите другие в config.env"; }
fi

ip_of() { getent ahostsv4 "$1" 2>/dev/null | awk '/STREAM/ && $1 !~ /^127\./ {print $1; exit}' || true; }

{
  echo "worker_processes 1;"
  echo "pid ${NGINX_DIR}/run/nginx.pid;"
  echo "error_log ${NGINX_DIR}/logs/error.log warn;"
  echo "events { worker_connections 512; }"
  echo "http {"
  echo "  include ${NGINX_APP_DIR}/etc/nginx/mime.types;"
  echo "  default_type application/octet-stream;"
  echo "  access_log ${NGINX_DIR}/logs/access.log;"
  echo "  client_body_temp_path ${NGINX_DIR}/tmp/body;"
  echo "  proxy_temp_path ${NGINX_DIR}/tmp/proxy;"
  echo "  fastcgi_temp_path ${NGINX_DIR}/tmp/fastcgi;"
  echo "  uwsgi_temp_path ${NGINX_DIR}/tmp/uwsgi;"
  echo "  scgi_temp_path ${NGINX_DIR}/tmp/scgi;"
  echo "  server_tokens off;"
  echo "  proxy_http_version 1.1;"
  echo "  proxy_set_header Accept-Encoding \"\";"
  echo "  proxy_set_header X-Forwarded-For \$remote_addr;"
  echo "  proxy_connect_timeout 10s;"
  echo "  proxy_read_timeout 120s;"
  echo "  sub_filter_once off;"
  echo "  sub_filter_types *;"
  while IFS=: read -r pub host port name; do
    [ -z "${pub}" ] && continue
    ip="$(ip_of "${host}")"
    [ -n "${ip}" ] || die "не резолвится ${host}"
    for src in "${host}:${port}" "${host}.${DNS_DOMAIN}:${port}" "${ip}:${port}"; do
      echo "  sub_filter '${src}' '${PUBLIC_HOST}:${pub}';"
      echo "  proxy_redirect http://${src}/ http://${PUBLIC_HOST}:${pub}/;"
    done
    if [ "${host}" = "${NN_HOST}" ] && [ "${port}" = "${PORT_DN_HTTP}" ]; then
      for src in "localhost:${port}" "127.0.0.1:${port}" "127.0.1.1:${port}"; do
        echo "  sub_filter '${src}' '${PUBLIC_HOST}:${pub}';"
      done
    fi
  done <<< "${WEB_MAP}"
  echo "  server {"
  echo "    listen ${NGINX_LISTEN}:${WEB_INDEX_PORT};"
  echo "    root ${NGINX_DIR}/www;"
  echo "    index index.html;"
  echo "  }"
  while IFS=: read -r pub host port name; do
    [ -z "${pub}" ] && continue
    echo "  server {"
    echo "    listen ${NGINX_LISTEN}:${pub};"
    echo "    location ~* ^/(logLevel|stacks) { return 403; }"
    echo "    location / {"
    echo "      limit_except GET HEAD { deny all; }"
    echo "      proxy_pass http://${host}:${port};"
    echo "    }"
    echo "  }"
  done <<< "${WEB_MAP}"
  echo "}"
} > "${NGX_CONF}"

{
  echo '<!doctype html><html><head><meta charset="utf-8"><title>Team 28 C — Hadoop Web UI</title>'
  echo '<style>body{font-family:sans-serif;max-width:720px;margin:40px auto;padding:0 16px}td{padding:6px 12px;border-bottom:1px solid #ddd}</style></head><body>'
  echo '<h1>Team 28 C — Hadoop / YARN Web UI</h1><table>'
  while IFS=: read -r pub host port name; do
    [ -z "${pub}" ] && continue
    echo "<tr><td>${name}</td><td><a href=\"http://${PUBLIC_HOST}:${pub}/\">http://${PUBLIC_HOST}:${pub}/</a></td><td>${host}:${port}</td></tr>"
  done <<< "${WEB_MAP}"
  echo '</table></body></html>'
} > "${NGINX_DIR}/www/index.html"

"${NGX[@]}" -t 2>&1 | grep -v 'the "user" directive' || true
"${NGX[@]}" -t >/dev/null 2>&1 || die "ошибка в конфиге nginx"
if [ "${running}" = yes ]; then
  "${NGX[@]}" -s reload; log "nginx перечитал конфиг"
else
  "${NGX[@]}"; log "nginx запущен"
fi
sleep 1

log "=== Проверка проксирования с edge ==="
fail=0
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WEB_INDEX_PORT}/" || true)"
echo "index           :${WEB_INDEX_PORT} -> ${code}"
while IFS=: read -r pub host port name; do
  [ -z "${pub}" ] && continue
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "http://127.0.0.1:${pub}/" || true)"
  printf '%-24s :%s -> %s:%s  HTTP %s\n' "${name}" "${pub}" "${host}" "${port}" "${code}"
  case "${code}" in 200|301|302|303|307) ;; *) fail=1;; esac
done <<< "${WEB_MAP}"
[ "${fail}" = 0 ] || die "часть интерфейсов не отвечает через nginx"
log "Все веб-интерфейсы опубликованы на edge (${NGINX_LISTEN})."
echo "Доступ с ноутбука через SSH-туннель:"
echo "  $(tunnel_cmd)"
echo "Затем откройте http://${PUBLIC_HOST}:${WEB_INDEX_PORT}/"
