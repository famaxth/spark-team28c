#!/usr/bin/env bash
set -euo pipefail
ORIG_PWD="$(pwd)"
cd "$(dirname "$0")/scripts"

case "${1:-all}" in
  all)
    ./00_preflight.sh
    ./01_install.sh
    ./02_configure.sh
    ./03_format.sh
    ./04_start.sh
    ./05_verify.sh
    ./07_yarn_configure.sh
    ./08_yarn_start.sh
    ./09_web_publish.sh
    ./10_yarn_verify.sh
    ./12_hive_install.sh
    ./13_hive_configure.sh
    ./14_hive_start.sh
    ./15_hive_load.sh
    ./16_hive_verify.sh
    ./18_spark_install.sh
    ./19_spark_run.sh
    ./20_spark_verify.sh ;;
  hdfs)
    ./00_preflight.sh
    ./01_install.sh
    ./02_configure.sh
    ./03_format.sh
    ./04_start.sh
    ./05_verify.sh ;;
  yarn)
    ./02_configure.sh
    ./07_yarn_configure.sh
    ./08_yarn_start.sh
    ./09_web_publish.sh
    ./10_yarn_verify.sh ;;
  hive)
    ./12_hive_install.sh
    ./13_hive_configure.sh
    ./14_hive_start.sh
    ./15_hive_load.sh
    ./16_hive_verify.sh ;;
  spark)
    ./18_spark_install.sh
    ./19_spark_run.sh
    ./20_spark_verify.sh ;;
  spark-install) ./18_spark_install.sh ;;
  spark-run)     ./19_spark_run.sh ;;
  spark-verify)  ./20_spark_verify.sh ;;
  hive-load)    f="${2:-}"; [ -z "${f}" ] || f="$(cd "${ORIG_PWD}" && readlink -f "${f}")"; ./15_hive_load.sh ${f:+"${f}"} ;;
  hive-verify)  ./16_hive_verify.sh ;;
  hive-start)   ./14_hive_start.sh ;;
  hive-stop)    ./17_hive_stop.sh ;;
  preflight)    ./00_preflight.sh ;;
  install)      ./01_install.sh ;;
  configure)    ./02_configure.sh; ./07_yarn_configure.sh ;;
  format)       ./03_format.sh ;;
  start)        ./04_start.sh; ./08_yarn_start.sh; ./09_web_publish.sh ;;
  web)          ./09_web_publish.sh ;;
  verify)       ./05_verify.sh; ./10_yarn_verify.sh ;;
  verify-yarn)  ./10_yarn_verify.sh ;;
  stop-yarn)    ./11_yarn_stop.sh ;;
  stop)         ./17_hive_stop.sh; ./11_yarn_stop.sh; ./06_stop.sh ;;
  *) echo "usage: $0 [all|hdfs|yarn|hive|spark|spark-install|spark-run|spark-verify|hive|hive-load [file.csv]|hive-verify|hive-start|hive-stop|preflight|install|configure|format|start|web|verify|verify-yarn|stop-yarn|stop]"; exit 2 ;;
esac
