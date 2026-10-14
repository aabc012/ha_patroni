#!/usr/bin/env bash
# Check one Patroni cluster through the first reachable node in its ip_list.

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./tp_cluster_status.sh primary
  ./tp_cluster_status.sh standby

The script reads dr_switchover.primary.conf or
dr_switchover.standby.conf from its own directory and tries each node in
ip_list until the remote patronictl command succeeds. It continues past
unreachable nodes and nodes where sudo/patronictl fails, then exits non-zero
if no node can provide a status.

Optional environment variables:
  SSH_USER=openpie
  PATRONICTL=/opt/miniconda3/envs/py311/bin/patronictl
  PATRONI_CONF=/opt/ha_pieclouddb_tp/patroni/patroni.yml
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

case "${1:-}" in
  primary|standby) cluster_kind=$1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[[ $# -eq 1 ]] || die 'exactly one cluster type is required'

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
conf="$script_dir/dr_switchover.${cluster_kind}.conf"
[[ -r "$conf" ]] || die "configuration file is not readable: $conf"

SSH_USER=${SSH_USER:-openpie}
PATRONICTL=${PATRONICTL:-/opt/miniconda3/envs/py311/bin/patronictl}
PATRONI_CONF=${PATRONI_CONF:-/opt/ha_pieclouddb_tp/patroni/patroni.yml}
[[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid SSH_USER: $SSH_USER"

unset ip_list host_list
# shellcheck disable=SC1090
source "$conf"
IFS=',' read -r -a nodes <<< "${ip_list:?missing ip_list in $conf}"
(( ${#nodes[@]} > 0 )) || die "$conf contains no nodes"
for node in "${nodes[@]}"; do
  [[ "$node" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "$conf contains an invalid node IP: $node"
done

command -v ssh >/dev/null 2>&1 || die 'ssh is required'

failures=()
for node in "${nodes[@]}"; do
  echo "Checking $cluster_kind cluster through $node ..." >&2
  set +e
  output=$(ssh -o BatchMode=yes -o ConnectTimeout=8 \
    -o ServerAliveInterval=5 -o ServerAliveCountMax=1 \
    "$SSH_USER@$node" \
    "sudo -n '$PATRONICTL' -c '$PATRONI_CONF' list" 2>&1)
  status=$?
  set -e

  if ((status == 255)); then
    failures+=("$node: SSH unavailable (exit $status)")
    echo "SSH to $node is unavailable; trying the next node." >&2
    continue
  fi
  if ((status != 0)); then
    failures+=("$node: remote status command failed (exit $status)")
    printf '%s\n' "$output" >&2
    echo "Status check failed on $node; trying the next node." >&2
    continue
  fi
  printf '%s\n' "$output"
  exit 0
done

echo "ERROR: unable to obtain $cluster_kind cluster status from any node; status check is abnormal." >&2
for failure in "${failures[@]}"; do
  echo "  - $failure" >&2
done
exit 1
