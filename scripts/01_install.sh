#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
guard_edge

mkdir -p "${DIST_DIR}"
HADOOP_TGZ="hadoop-${HADOOP_VERSION}.tar.gz"
JDK_TGZ="temurin-jdk${JAVA_MAJOR}.tar.gz"

ARCH="$(rsh "${NN_HOST}" 'uname -m')"
case "${ARCH}" in x86_64) JARCH=x64;; aarch64) JARCH=aarch64;; *) die "неизвестная архитектура ${ARCH}";; esac

fetch() {
  curl -fL --retry 3 --connect-timeout 20 -o "$2.part" "$1" && mv "$2.part" "$2"
}

cd "${DIST_DIR}" || exit 1
if [ ! -s "${HADOOP_TGZ}" ]; then
  log "Скачиваю Hadoop ${HADOOP_VERSION}"
  for base in "https://dlcdn.apache.org/hadoop/common" "https://archive.apache.org/dist/hadoop/common"; do
    if fetch "${base}/hadoop-${HADOOP_VERSION}/${HADOOP_TGZ}" "${HADOOP_TGZ}" \
       && fetch "${base}/hadoop-${HADOOP_VERSION}/${HADOOP_TGZ}.sha512" "${HADOOP_TGZ}.sha512"; then break; fi
  done
  [ -s "${HADOOP_TGZ}" ] || die "не удалось скачать Hadoop. Положите ${HADOOP_TGZ} в ${DIST_DIR} вручную"
fi
if [ -s "${HADOOP_TGZ}.sha512" ]; then
  want="$(grep -oE '[0-9a-f]{128}' "${HADOOP_TGZ}.sha512" | sed -n 1p || true)"
  have="$(sha512sum "${HADOOP_TGZ}" | cut -d' ' -f1)"
  [ "${want}" = "${have}" ] || die "sha512 Hadoop не совпадает — удалите ${DIST_DIR}/${HADOOP_TGZ} и повторите"
  log "sha512 Hadoop OK"
fi
if [ ! -s "${JDK_TGZ}" ]; then
  log "Скачиваю Temurin JDK ${JAVA_MAJOR} (${JARCH})"
  fetch "https://api.adoptium.net/v3/binary/latest/${JAVA_MAJOR}/ga/linux/${JARCH}/jdk/hotspot/normal/eclipse" "${JDK_TGZ}" \
    || die "не удалось скачать JDK. Положите ${JDK_TGZ} в ${DIST_DIR} вручную"
fi
JDK_TOP="$(tar -tzf "${JDK_TGZ}" 2>/dev/null | sed -n 1p | cut -d/ -f1 || true)"
[ -n "${JDK_TOP}" ] || die "не удалось прочитать архив ${JDK_TGZ}"
cd - >/dev/null || exit 1

for h in ${ALL_NODES}; do
  log "=== ${h} ==="
  state="$(rsh "${h}" "
    j=no; hd=no
    [ -x ${JAVA_DIR}/bin/java ] && ${JAVA_DIR}/bin/java -version 2>&1 | grep -q '\"${JAVA_MAJOR}\\.' && j=yes
    [ -x ${HADOOP_DIR}/bin/hdfs ] && [ \"\$(readlink -f ${HADOOP_DIR})\" = '${APPS_DIR}/hadoop-${HADOOP_VERSION}' ] && hd=yes
    echo \$j \$hd")"
  read -r has_java has_hadoop <<< "${state}"

  rsh "${h}" "mkdir -p ${DIST_DIR} ${APPS_DIR}"
  if [ "${has_java}" = yes ]; then
    echo "Java ${JAVA_MAJOR} уже установлена"
  else
    log "${h}: ставлю JDK -> ${APPS_DIR}/${JDK_TOP}"
    rcopy "${DIST_DIR}/${JDK_TGZ}" "${h}" "${DIST_DIR}/${JDK_TGZ}"
    rsh "${h}" "tar -xzf ${DIST_DIR}/${JDK_TGZ} -C ${APPS_DIR} && ln -sfn ${APPS_DIR}/${JDK_TOP} ${JAVA_DIR}"
  fi
  if [ "${has_hadoop}" = yes ]; then
    echo "Hadoop ${HADOOP_VERSION} уже установлен"
  else
    log "${h}: ставлю Hadoop -> ${APPS_DIR}/hadoop-${HADOOP_VERSION}"
    rcopy "${DIST_DIR}/${HADOOP_TGZ}" "${h}" "${DIST_DIR}/${HADOOP_TGZ}"
    rsh "${h}" "tar -xzf ${DIST_DIR}/${HADOOP_TGZ} -C ${APPS_DIR} && ln -sfn ${APPS_DIR}/hadoop-${HADOOP_VERSION} ${HADOOP_DIR}"
  fi
  rsh "${h}" "${JAVA_DIR}/bin/java -version 2>&1 | sed -n 1p; JAVA_HOME=${JAVA_DIR} ${HADOOP_DIR}/bin/hadoop version | sed -n 1p"
done
log "Установка завершена."
