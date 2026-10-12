#!/bin/sh
set -eu
policy=${BATTLESHIP_NUMA_POLICY:-cpuset}
case "$policy" in
  cpuset) exec "$@" ;;
  membind)
    mems=${BATTLESHIP_NUMA_MEMS:-}
    case "$mems" in ''|*[!0-9,]*) echo 'Battleship NUMA: invalid memory node list' >&2; exit 64 ;; esac
    command -v numactl >/dev/null 2>&1 || { echo 'Battleship NUMA: numactl is missing' >&2; exit 69; }
    # exec preserves PID 1 and signals; numactl failure never starts the server.
    exec numactl --membind="$mems" "$@"
    ;;
  *) echo 'Battleship NUMA: policy must be cpuset or membind' >&2; exit 64 ;;
esac
