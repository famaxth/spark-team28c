#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
guard_edge

fetch() { curl -fL --retry 3 --connect-timeout 20 -o "$2.part" "$1" && mv "$2.part" "$2"; }
mkdir -p "${DIST_DIR}" "${APPS_DIR}"

log "=== Java и Hadoop-клиент на edge ==="
if ! "${JAVA_DIR}/bin/java" -version 2>&1 | grep -q "\"${JAVA_MAJOR}\."; then
  JDK_TGZ="${DIST_DIR}/temurin-jdk${JAVA_MAJOR}.tar.gz"
  [ -s "${JDK_TGZ}" ] || die "нет ${JDK_TGZ} — сначала ./deploy.sh install"
  top="$(tar -tzf "${JDK_TGZ}" 2>/dev/null | sed -n 1p | cut -d/ -f1 || true)"
  tar -xzf "${JDK_TGZ}" -C "${APPS_DIR}" && ln -sfn "${APPS_DIR}/${top}" "${JAVA_DIR}"
fi
if [ "$(readlink -f "${HADOOP_DIR}" 2>/dev/null)" != "${APPS_DIR}/hadoop-${HADOOP_VERSION}" ]; then
  HTGZ="${DIST_DIR}/hadoop-${HADOOP_VERSION}.tar.gz"
  [ -s "${HTGZ}" ] || die "нет ${HTGZ} — сначала ./deploy.sh install"
  tar -xzf "${HTGZ}" -C "${APPS_DIR}" && ln -sfn "${APPS_DIR}/hadoop-${HADOOP_VERSION}" "${HADOOP_DIR}"
fi
CONF="${HADOOP_DIR}/etc/hadoop"
for f in core-site.xml hdfs-site.xml yarn-site.xml mapred-site.xml capacity-scheduler.xml; do
  scp -q "${SSH_OPTS[@]}" "${TEAM_USER}@${JHS_HOST}:${CONF}/${f}" "${CONF}/${f}"
done
cat > "${CONF}/hadoop-env.sh" <<EOF
export JAVA_HOME=${JAVA_DIR}
export HADOOP_HOME=${HADOOP_DIR}
export HADOOP_CONF_DIR=${CONF}
export HADOOP_LOG_DIR=${LOG_DIR}
export HADOOP_PID_DIR=${PID_DIR}
export HADOOP_IDENT_STRING=${TEAM_USER}
export HADOOP_HEAPSIZE_MAX=512m
EOF
"${JAVA_DIR}/bin/java" -version 2>&1 | sed -n 1p
JAVA_HOME="${JAVA_DIR}" "${HADOOP_DIR}/bin/hdfs" getconf -confKey fs.defaultFS

log "=== Apache Hive ${HIVE_VERSION} ==="
HIVE_TGZ="apache-hive-${HIVE_VERSION}-bin.tar.gz"
if [ "$(readlink -f "${HIVE_DIR}" 2>/dev/null)" != "${APPS_DIR}/apache-hive-${HIVE_VERSION}-bin" ]; then
  if [ ! -s "${DIST_DIR}/${HIVE_TGZ}" ]; then
    for base in "https://archive.apache.org/dist/hive" "https://dlcdn.apache.org/hive"; do
      fetch "${base}/hive-${HIVE_VERSION}/${HIVE_TGZ}" "${DIST_DIR}/${HIVE_TGZ}" && break
    done
  fi
  [ -s "${DIST_DIR}/${HIVE_TGZ}" ] || die "не удалось скачать Hive"
  if fetch "https://archive.apache.org/dist/hive/hive-${HIVE_VERSION}/${HIVE_TGZ}.sha256" "${DIST_DIR}/${HIVE_TGZ}.sha256" 2>/dev/null; then
    want="$(grep -oE '[0-9a-f]{64}' "${DIST_DIR}/${HIVE_TGZ}.sha256" | sed -n 1p || true)"
    have="$(sha256sum "${DIST_DIR}/${HIVE_TGZ}" | cut -d' ' -f1)"
    [ "${want}" = "${have}" ] || die "sha256 Hive не совпадает — удалите ${DIST_DIR}/${HIVE_TGZ}"
    log "sha256 Hive OK"
  fi
  tar -xzf "${DIST_DIR}/${HIVE_TGZ}" -C "${APPS_DIR}"
  ln -sfn "${APPS_DIR}/apache-hive-${HIVE_VERSION}-bin" "${HIVE_DIR}"
fi

hadoop_guava="$(ls "${HADOOP_DIR}"/share/hadoop/common/lib/guava-*.jar 2>/dev/null | sed -n 1p || true)"
if [ -n "${hadoop_guava}" ]; then
  mkdir -p "${HIVE_DIR}/lib-disabled"
  for g in "${HIVE_DIR}"/lib/guava-*.jar; do
    [ -e "${g}" ] || continue
    [ "$(basename "${g}")" = "$(basename "${hadoop_guava}")" ] && continue
    mv "${g}" "${HIVE_DIR}/lib-disabled/"
  done
  [ -e "${HIVE_DIR}/lib/$(basename "${hadoop_guava}")" ] || cp "${hadoop_guava}" "${HIVE_DIR}/lib/"
  echo "guava: $(cd "${HIVE_DIR}/lib" && ls guava-*.jar)"
fi

if ! ls "${HIVE_DIR}"/lib/postgresql-*.jar >/dev/null 2>&1; then
  log "PostgreSQL JDBC-драйвер"
  mkdir -p "${DIST_DIR}/pgjdbc"
  if ! fetch "https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.4/postgresql-42.7.4.jar" "${HIVE_DIR}/lib/postgresql-42.7.4.jar"; then
    ( cd "${DIST_DIR}/pgjdbc" && apt-get download libpostgresql-jdbc-java >/dev/null )
    dpkg -x "$(ls "${DIST_DIR}"/pgjdbc/libpostgresql-jdbc-java_*.deb | sed -n 1p)" "${DIST_DIR}/pgjdbc/x"
    cp "$(readlink -f "${DIST_DIR}/pgjdbc/x/usr/share/java/postgresql.jar")" "${HIVE_DIR}/lib/postgresql-jdbc.jar"
  fi
fi
ls "${HIVE_DIR}"/lib/postgresql-*.jar

mkdir -p "${HIVE_DIR}/auxlib"
if ! ls "${HIVE_DIR}"/auxlib/commons-collections-3*.jar >/dev/null 2>&1; then
  cc="$(ls "${HIVE_DIR}"/lib/commons-collections-3*.jar 2>/dev/null | sed -n 1p || true)"
  if [ -n "${cc}" ]; then
    cp "${cc}" "${HIVE_DIR}/auxlib/"
  else
    mkdir -p "${DIST_DIR}/cc3"
    ( cd "${DIST_DIR}/cc3" && apt-get download libcommons-collections3-java >/dev/null )
    dpkg -x "$(ls "${DIST_DIR}"/cc3/libcommons-collections3-java_*.deb | sed -n 1p)" "${DIST_DIR}/cc3/x"
    cp "$(readlink -f "${DIST_DIR}/cc3/x/usr/share/java/commons-collections3.jar")" "${HIVE_DIR}/auxlib/commons-collections-3.jar"
  fi
fi
echo "auxlib (передаётся в задачи MapReduce): $(cd "${HIVE_DIR}/auxlib" && ls)"

log "=== PostgreSQL ${PG_MAJOR} (без sudo) ==="
PGBIN="${PG_APP_DIR}/usr/lib/postgresql/${PG_MAJOR}/bin"
if [ ! -x "${PGBIN}/postgres" ]; then
  mkdir -p "${DIST_DIR}/pgsql" "${PG_APP_DIR}"
  ( cd "${DIST_DIR}/pgsql" && apt-get download "postgresql-${PG_MAJOR}" "postgresql-client-${PG_MAJOR}" libpq5 >/dev/null )
  for deb in "${DIST_DIR}"/pgsql/*.deb; do dpkg -x "${deb}" "${PG_APP_DIR}"; done
fi
export LD_LIBRARY_PATH="${PG_APP_DIR}/usr/lib/x86_64-linux-gnu"
missing="$(for b in postgres initdb pg_ctl psql; do ldd "${PGBIN}/${b}"; done | grep 'not found' | sort -u || true)"
[ -z "${missing}" ] || { echo "${missing}"; die "не хватает системных библиотек для PostgreSQL"; }
"${PGBIN}/postgres" --version

log "Установка Hive и PostgreSQL завершена."
