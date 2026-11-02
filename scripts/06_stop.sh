#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
guard_edge

stop_daemon() {
  log "${1}: stop ${2}"
  rsh "$1" "$HENV; hdfs --daemon stop $2 || true"
}

stop_daemon "${SNN_HOST}" secondarynamenode
for h in ${DN_HOSTS}; do stop_daemon "${h}" datanode; done
stop_daemon "${NN_HOST}" namenode

for h in ${ALL_NODES}; do
  echo "${h}: $(rsh "${h}" "$HENV; jps | grep -vw Jps | tr '\n' ' '")"
done
