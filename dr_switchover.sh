#!/usr/bin/env bash
# Execute one DR switchover phase on the local Patroni cluster.
#
# This script deliberately implements one phase per invocation.  A normal
# switchover is performed in this order:
#   1. fence   - stop writes on the current primary cluster;
#   2. promote - convert the current standby cluster into a primary;
#   3. rejoin  - rebuild the former primary as the new standby.
#
# The commands must be run from the operations host for the cluster named by
# --conf.  The operations host only needs passwordless root SSH access to its
# own cluster; the peer is reached through its VIP for PostgreSQL checks.

set -Eeuo pipefail

# Print the supported phases and the operational assumptions.  In particular,
# emergency-promote is intentionally not a fencing operation: the old primary
# must be isolated outside this script before it is used.
usage() {
  cat <<'EOF'
Usage:
  ./dr_switchover.sh fence   --conf <current-primary.conf>
  ./dr_switchover.sh promote --conf <current-standby.conf>
  ./dr_switchover.sh rejoin  --conf <former-primary.conf>
  ./dr_switchover.sh finalize-promote --conf <new-primary.conf>
  ./dr_switchover.sh emergency-promote --conf <current-standby.conf>

Run each phase from the operations host for that cluster. It must have
passwordless root SSH access to every node in the local cluster.

When SSH_USER is not root, that user must have passwordless sudo (sudo -n)
on every target node; the remote operations still require root privileges.

Each configuration defines a comma-separated ip_list for the local nodes and
two directional slots: local_replication_slot_name
is consumed when this cluster rejoins as a standby; peer_replication_slot_name
is consumed by the other cluster and is created here after promotion. The
peer_cluster_vip and peer_cluster_pg_port always identify the other cluster,
regardless of which cluster is currently writable.

emergency-promote is for an unreachable primary. It does not contact or fence
the former primary; isolate that primary at the network/storage/VIP layer first.

finalize-promote completes a promotion that already succeeded but whose script
run stopped before it could create the return replication slot.

Optional environment variables:
  PATRONICTL=/path/to/patronictl   (default: /opt/miniconda3/envs/py311/bin/patronictl)
  SSH_USER=openpie               (default: current execution user)
  PYTHON=/path/to/python         (default: python3, used for JSON parsing in this Pod)
  PSQL=/path/to/psql               (default: /opt/pieclouddb-tp/bin/psql)
  WAIT_SECONDS=180                 (default: 180)
  MAX_PREFLIGHT_LAG_BYTES=16777216 (default: 16 MiB)
  MAX_SWITCHOVER_LAG_BYTES=0       (default: 0)
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

# The first positional argument selects exactly one state transition.  The
# remaining arguments are parsed separately so that --conf can appear after it.
stage=${1:-}
[[ -n "$stage" ]] && shift || true
if [[ "$stage" == -h || "$stage" == --help ]]; then
  usage
  exit 0
fi
conf=''
while (($#)); do
  case "$1" in
    --conf) conf=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done
[[ "$stage" == fence || "$stage" == promote || "$stage" == rejoin || "$stage" == emergency-promote || "$stage" == finalize-promote ]] || { usage >&2; exit 2; }
[[ -n "$conf" && -r "$conf" ]] || die '--conf must be a readable file'

PATRONICTL=${PATRONICTL:-/opt/miniconda3/envs/py311/bin/patronictl}
PSQL=${PSQL:-/opt/pieclouddb-tp/bin/psql}
PG_CTL=${PG_CTL:-/opt/pieclouddb-tp/bin/pg_ctl}
PDB_ENV=${PDB_ENV:-/opt/pieclouddb-tp/pdb_env.sh}
SSH_USER=${SSH_USER:-${USER:-root}}
PYTHON=${PYTHON:-python3}
WAIT_SECONDS=${WAIT_SECONDS:-180}
MAX_PREFLIGHT_LAG_BYTES=${MAX_PREFLIGHT_LAG_BYTES:-16777216}
MAX_SWITCHOVER_LAG_BYTES=${MAX_SWITCHOVER_LAG_BYTES:-0}
# These values are embedded in remote commands/SQL, so reject non-numeric
# timeout and lag settings before any cluster operation begins.
[[ "$WAIT_SECONDS" =~ ^[0-9]+$ && "$MAX_PREFLIGHT_LAG_BYTES" =~ ^[0-9]+$ && "$MAX_SWITCHOVER_LAG_BYTES" =~ ^[0-9]+$ ]] || die 'wait and lag settings must be non-negative integers'
command -v ssh >/dev/null 2>&1 || die 'ssh is required in the execution Pod'
command -v awk >/dev/null 2>&1 || die 'awk is required in the execution Pod'
command -v "$PYTHON" >/dev/null 2>&1 || die "JSON parser not found: $PYTHON; install Python 3 or set PYTHON=/path/to/python"
[[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid SSH_USER: $SSH_USER"

# Clear variables before sourcing the configuration.  This prevents values
# inherited from the caller's shell from silently filling missing config keys.
unset ip_list tp_data vip peer_cluster_vip peer_cluster_pg_port local_replication_slot_name peer_replication_slot_name patroni_scope
unset primary_cluster_vip primary_cluster_pg_port
# shellcheck disable=SC1090
source "$conf"
if [[ -n ${primary_cluster_vip:-} || -n ${primary_cluster_pg_port:-} ]]; then
  die "$conf uses obsolete primary_cluster_* fields; rename them to peer_cluster_vip and peer_cluster_pg_port"
fi
IFS=',' read -r -a nodes <<< "${ip_list:?missing ip_list in $conf}"
for node in "${nodes[@]}"; do
  [[ "$node" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$conf contains an invalid node IP: $node"
done
(( ${#nodes[@]} > 0 )) || die "$conf must contain at least one node IP"
data_dir=${tp_data:?missing tp_data in $conf}
cluster_vip=${vip:?missing vip in $conf}
peer_vip=${peer_cluster_vip:?missing peer_cluster_vip in $conf}
peer_pg_port=${peer_cluster_pg_port:?missing peer_cluster_pg_port in $conf}
local_slot_name=${local_replication_slot_name:?missing local_replication_slot_name in $conf}
peer_slot_name=${peer_replication_slot_name:?missing peer_replication_slot_name in $conf}
expected_scope=${patroni_scope:-pieclouddb-tp}
# Values are later passed through SSH, shell snippets, and SQL.  Keep the
# accepted alphabet deliberately narrow; slot names are checked again by
# safe_value() at the point where they are used.
safe_config_pattern='^[a-zA-Z0-9._:/-]+$'
[[ "$cluster_vip" =~ $safe_config_pattern && "$peer_vip" =~ $safe_config_pattern && "$peer_pg_port" =~ ^[0-9]+$ && "$local_slot_name" =~ ^[a-zA-Z0-9_]+$ && "$peer_slot_name" =~ ^[a-zA-Z0-9_]+$ && "$expected_scope" =~ ^[a-zA-Z0-9_.-]+$ ]] || die "$conf contains an unsafe DR configuration value"
ha_dir=$(awk -F= '/^[[:space:]]*(export[[:space:]]+)?ha_tp_dir=/{gsub(/["[:space:]]/, "", $2); print $2; exit}' "$conf")
ha_dir=${ha_dir:-/opt/ha_pieclouddb_tp}
patroni_conf="$ha_dir/patroni/patroni.yml"
# The first reachable node is used as the control node for patronictl, DCS,
# REST API, and peer-VIP connectivity checks.  It is not assumed to be leader.
control_host=${nodes[0]}

# BatchMode prevents an interactive password prompt from hanging an operation.
# Non-root SSH users need passwordless sudo because the remote phases stop
# services, edit system configuration, and move PostgreSQL data directories.
ssh_root() {
  local host=$1
  shift
  if [[ "$SSH_USER" == root ]]; then
    ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$host" "$@"
  elif [[ "${1:-}" == bash && "${2:-}" == -s ]]; then
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_USER@$host" sudo -n "$@"
  else
    # Feed the command as a script so embedded quotes (REST JSON, SQL, awk)
    # survive the SSH and remote shell boundaries.
    printf '%s\n' "$*" | ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_USER@$host" sudo -n bash -s
  fi
}
stop_vip_node() { ssh_root "$1" 'systemctl stop tp_vip 2>/dev/null || true'; }
stop_cluster_node() {
  local host=$1
  ssh_root "$host" bash -s -- "$data_dir" "$PG_CTL" <<'REMOTE'
set -Eeuo pipefail
data_dir=$1
pg_ctl=$2
systemctl stop tp_vip 2>/dev/null || true
systemctl stop patroni 2>/dev/null || true
# Avoid runuser warning when the SSH session starts in root's private home.
cd /

# Some existing patroni.service files use KillMode=process, which leaves the
# PostgreSQL child process running after Patroni exits. Stop this exact PGDATA
# explicitly, then verify that no process still owns it.
if [ -f "$data_dir/postmaster.pid" ]; then
  runuser -u openpie -- "$pg_ctl" -D "$data_dir" stop -m fast -w -t 90
fi
if runuser -u openpie -- "$pg_ctl" -D "$data_dir" status >/dev/null 2>&1; then
  echo "PostgreSQL is still running for $data_dir" >&2
  exit 1
fi
REMOTE
}
patronictl() {
  # Keep stdin attached to patronictl.  `patronictl remove` is interactive;
  # routing the command through `sudo bash -s` would consume its confirmation
  # input in the remote shell and make patronictl report `Aborted!`.
  if [[ "$SSH_USER" == root ]]; then
    ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$control_host" \
      "$PATRONICTL" -c "$patroni_conf" "$@"
  else
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_USER@$control_host" \
      sudo -n "$PATRONICTL" -c "$patroni_conf" "$@"
  fi
}
cluster_json() { patronictl list -f json; }
# Read the static scope from the deployed Patroni file and compare it with the
# operation config before touching the cluster's DCS state.
cluster_scope() { ssh_root "$control_host" "awk -F ': *' '/^scope:/ {print \$2; exit}' '$patroni_conf'"; }
# Patroni's /config endpoint exposes the effective dynamic DCS configuration,
# which is more authoritative than the local YAML file during a live run.
dynamic_config() { ssh_root "$control_host" 'curl --fail --silent --show-error http://127.0.0.1:8008/config'; }
assert_primary_cluster_config() {
  dynamic_config | "$PYTHON" -c '
import json, sys
if json.load(sys.stdin).get("standby_cluster"):
    raise SystemExit("DCS still configures this cluster as a standby")
' || die 'current primary DCS configuration is not writable-cluster mode'
}
assert_standby_cluster_config() {
  local expected_host=$1 expected_slot=$2
  dynamic_config | "$PYTHON" -c '
import json, sys
expected_host, expected_slot = sys.argv[1:]
standby = json.load(sys.stdin).get("standby_cluster") or {}
if str(standby.get("host", "")) != expected_host or standby.get("primary_slot_name") != expected_slot:
    raise SystemExit(f"standby_cluster mismatch: {standby}")
' "$expected_host" "$expected_slot" || die "DCS standby configuration does not match $expected_host / $expected_slot"
}
leader_host() {
  cluster_json | "$PYTHON" -c '
import json, sys
for member in json.load(sys.stdin):
    if member.get("Role", "").lower() in ("leader", "primary", "master", "standby leader", "standby_leader"):
        print(member["Host"]); break
else: raise SystemExit("No leader found")'
}
primary_host() {
  cluster_json | "$PYTHON" -c '
import json, sys
for member in json.load(sys.stdin):
    if member.get("Role", "").lower() in ("leader", "primary", "master"):
        print(member["Host"]); break
else: raise SystemExit("No writable leader found")'
}
assert_cluster_healthy() {
  local expected_leader_role=$1 expected_count=${#nodes[@]}
  cluster_json | "$PYTHON" -c '
import json, sys
expected_role, expected_count = sys.argv[1], int(sys.argv[2])
members = json.load(sys.stdin)
roles = [m.get("Role", "").lower().replace("_", " ") for m in members]
states = [m.get("State", "").lower() for m in members]
leaders = {"writable": {"leader", "primary", "master"}, "standby": {"standby leader"}}[expected_role]
if len(members) != expected_count or sum(role in leaders for role in roles) != 1:
    raise SystemExit(f"unexpected members or roles: {roles}")
if any(state not in {"running", "streaming"} for state in states):
    raise SystemExit(f"unhealthy member states: {states}")
' "$expected_leader_role" "$expected_count" || die "$expected_leader_role cluster is not fully healthy"
}
role_is() {
  local host=$1 expected=$2
    ssh_root "$host" 'curl --fail --silent --show-error http://127.0.0.1:8008/patroni' | \
    "$PYTHON" -c "import json,sys; raise SystemExit(0 if json.load(sys.stdin).get('role') in ${expected} else 1)"
}
wait_for_primary_host() {
  local elapsed=0 host
  while ((elapsed < WAIT_SECONDS)); do
    if host=$(primary_host 2>/dev/null); then
      printf '%s' "$host"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}
# This is called before values are interpolated into shell commands or SQL.
safe_value() { [[ "$1" =~ ^[a-zA-Z0-9._:/-]+$ ]] || die "unsafe configuration value: $1"; }
complete_promotion() {
  local primary
  primary=$(primary_host) || die 'new primary leader is not available'
  log "Creating peer rejoin slot $peer_slot_name on new primary $primary."
  create_replication_slot "$primary" "$peer_slot_name"
}
remove_cluster_from_dcs() {
  local scope=$1 attempt members leader_member confirmations
  # Patroni 3.3.x has no --force option. A recently stopped leader lease may
  # cause a third confirmation prompt; retry until its TTL expires. An empty
  # member list does not imply empty DCS state: initialize/config/status keys
  # may remain after member leases expire, so always issue remove here.
  for attempt in 1 2 3 4 5; do
    members=$(patronictl list -f json) || die "unable to inspect Patroni DCS members for $scope"
    leader_member=$(printf '%s\n' "$members" | "$PYTHON" -c '
import json, sys
leaders = {"leader", "primary", "master", "standby leader", "standby_leader"}
for member in json.load(sys.stdin):
    if member.get("Role", "").lower() in leaders:
        print(member.get("Member", ""))
        break
' ) || die "unable to identify the current Patroni leader for $scope"
    confirmations=$(printf '%s\n%s\n' "$scope" 'Yes I am aware')
    [[ -z "$leader_member" ]] || confirmations+=$(printf '\n%s' "$leader_member")
    if printf '%s\n' "$confirmations" | patronictl remove "$scope"; then
      return 0
    fi
    log "DCS removal is waiting for the former leader lease to expire (attempt $attempt/5)."
    sleep 10
  done
  die "unable to remove Patroni DCS state for $scope"
}
create_replication_slot() {
  local primary=$1 slot=$2
  safe_value "$slot"
  ssh_root "$primary" bash -s -- "$PSQL" "$slot" "$PDB_ENV" "$patroni_conf" <<'REMOTE'
set -Eeuo pipefail
psql_bin=$1
slot=$2
pdb_env=$3
patroni_conf=$4
test -r "$pdb_env"
test -r "$patroni_conf"
pg_password=$(awk '/^    superuser:/{found=1; next} found && /^      password:/{print $2; exit}' "$patroni_conf")
test -n "$pg_password"
# pdb_env.sh provides the TP library path required by psql.  The password is
# read from the deployed Patroni config rather than stored in the DR config.
# shellcheck disable=SC1090
set +u
source "$pdb_env"
set -u
export PGPASSWORD="$pg_password"
"$psql_bin" -h 127.0.0.1 -U openpie -d postgres -v ON_ERROR_STOP=1 \
  -c "SELECT pg_create_physical_replication_slot('${slot}') WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = '${slot}');" >/dev/null
slot_exists=$("$psql_bin" -h 127.0.0.1 -U openpie -d postgres -At -v ON_ERROR_STOP=1 \
  -c "SELECT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = '${slot}');")
[[ "$slot_exists" == t ]] || {
  echo "replication slot $slot was not created on the promoted primary" >&2
  exit 1
}
REMOTE
}
prepare_upstream() {
  local upstream=$1 port=$2 slot=$3
  safe_value "$upstream"; safe_value "$port"; safe_value "$slot"
  ssh_root "$control_host" bash -s -- "$PSQL" "$upstream" "$port" "$slot" "$PDB_ENV" "$patroni_conf" <<'REMOTE'
set -Eeuo pipefail
psql_bin=$1 upstream=$2 port=$3 slot=$4 pdb_env=$5 patroni_conf=$6
test -r "$pdb_env"
test -r "$patroni_conf"
pg_password=$(awk '/^    superuser:/{found=1; next} found && /^      password:/{print $2; exit}' "$patroni_conf")
test -n "$pg_password"
# shellcheck disable=SC1090
set +u
source "$pdb_env"
set -u
export PGPASSWORD="$pg_password"
is_writable=$("$psql_bin" -h "$upstream" -p "$port" -U openpie -d postgres -At -v ON_ERROR_STOP=1 \
  -c "SELECT NOT pg_is_in_recovery();")
[[ "$is_writable" == t ]] || {
  echo "Upstream $upstream:$port is not writable" >&2
  exit 1
}
slot_state=$("$psql_bin" -h "$upstream" -p "$port" -U openpie -d postgres -At -v ON_ERROR_STOP=1 \
  -c "SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = '${slot}') THEN 'missing' WHEN EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = '${slot}' AND slot_type = 'physical' AND NOT temporary) THEN 'ready' ELSE 'incompatible' END;")
if [[ "$slot_state" == missing ]]; then
  echo "Replication slot $slot is absent on $upstream:$port; creating it before rejoin."
  "$psql_bin" -h "$upstream" -p "$port" -U openpie -d postgres -v ON_ERROR_STOP=1 \
    -c "SELECT pg_create_physical_replication_slot('${slot}');" >/dev/null
elif [[ "$slot_state" != ready ]]; then
  echo "Upstream slot $slot exists but is not a permanent physical replication slot" >&2
  exit 1
fi
slot_ready=$("$psql_bin" -h "$upstream" -p "$port" -U openpie -d postgres -At -v ON_ERROR_STOP=1 \
  -c "SELECT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = '${slot}' AND slot_type = 'physical' AND NOT temporary);")
[[ "$slot_ready" == t ]] || {
  echo "Physical replication slot $slot is not ready on $upstream:$port" >&2
  exit 1
}
REMOTE
}
peer_replication_is_streaming() {
  local primary=$1 slot=$2 max_lag=$3
  safe_value "$slot"
  ssh_root "$primary" bash -s -- "$PSQL" "$slot" "$max_lag" "$PDB_ENV" "$patroni_conf" <<'REMOTE'
set -Eeuo pipefail
psql_bin=$1 slot=$2 max_lag=$3 pdb_env=$4 patroni_conf=$5
test -r "$pdb_env"
pg_password=$(awk '/^    superuser:/{found=1; next} found && /^      password:/{print $2; exit}' "$patroni_conf")
test -n "$pg_password"
set +u
source "$pdb_env"
set -u
export PGPASSWORD="$pg_password"
# Join the slot to its active replication connection so an existing but
# unused slot is not mistaken for a healthy standby.
result=$("$psql_bin" -h 127.0.0.1 -U openpie -d postgres -At -v ON_ERROR_STOP=1 -c \
  "SELECT COALESCE((SELECT r.state = 'streaming' AND pg_wal_lsn_diff(pg_current_wal_lsn(), r.replay_lsn) <= ${max_lag} FROM pg_replication_slots s JOIN pg_stat_replication r ON r.pid = s.active_pid WHERE s.slot_name = '${slot}'), false);")
[[ "$result" == t ]]
REMOTE
}
wait_for_peer_catchup() {
  local primary=$1 slot=$2 elapsed=0
  while ((elapsed < WAIT_SECONDS)); do
    if peer_replication_is_streaming "$primary" "$slot" "$MAX_SWITCHOVER_LAG_BYTES"; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}
standby_replay_is_ready() {
  local standby_leader=$1
  ssh_root "$standby_leader" bash -s -- "$PSQL" "$PDB_ENV" "$patroni_conf" <<'REMOTE'
set -Eeuo pipefail
psql_bin=$1 pdb_env=$2 patroni_conf=$3
pg_password=$(awk '/^    superuser:/{found=1; next} found && /^      password:/{print $2; exit}' "$patroni_conf")
test -n "$pg_password"
set +u
source "$pdb_env"
set -u
export PGPASSWORD="$pg_password"
result=$("$psql_bin" -h 127.0.0.1 -U openpie -d postgres -At -v ON_ERROR_STOP=1 -c \
  "SELECT pg_is_in_recovery() AND NOT pg_is_wal_replay_paused() AND pg_last_wal_receive_lsn() IS NOT NULL AND pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn();")
[[ "$result" == t ]]
REMOTE
}
peer_accepts_database_connections() {
  local peer=$1 port=$2
  safe_value "$peer"; safe_value "$port"
  ssh_root "$control_host" bash -s -- "$peer" "$port" <<'REMOTE'
peer=$1 port=$2
command -v timeout >/dev/null || exit 2
rc=0
timeout 5 bash -c 'exec 3<>/dev/tcp/$1/$2' _ "$peer" "$port" || rc=$?
[[ "$rc" == 0 ]] && exit 0
[[ "$rc" == 1 || "$rc" == 124 ]] && exit 1
exit 2
REMOTE
}

reachable_hosts=()
# Validate SSH and the VIP-manager configuration on every local node before
# asking Patroni for cluster state.  emergency-promote is the only phase that
# tolerates unreachable local nodes; it still requires at least one reachable
# node and a usable DCS quorum/standby leader.
for host in "${nodes[@]}"; do
  if ! ssh_root "$host" true; then
    if [[ "$stage" == emergency-promote ]]; then
      log "WARNING: local cluster node $host is unreachable during emergency promotion."
      continue
    fi
    die "root SSH unavailable in this cluster: $host"
  fi
  reachable_hosts+=("$host")
  configured_vip=$(ssh_root "$host" "awk -F ': *' '/^ip:/ {print \$2; exit}' '$ha_dir/tp_vip/vip_manager.yml'")
  [[ "$configured_vip" == "$cluster_vip" ]] || die "$host VIP configuration ($configured_vip) does not match $conf ($cluster_vip)"
done
((${#reachable_hosts[@]} > 0)) || die 'no local cluster node is reachable'
control_host=${reachable_hosts[0]}
actual_scope=$(cluster_scope)
[[ "$actual_scope" == "$expected_scope" ]] || die "Patroni scope $actual_scope does not match configured scope $expected_scope"

case "$stage" in
  fence)
    # Planned switchover: stop the writable cluster only after its peer is
    # healthy and within the configured preflight lag limit.
    scope=$actual_scope
    assert_primary_cluster_config
    assert_cluster_healthy writable
    leader=$(primary_host) || die 'current primary cluster has no writable leader'
    role_is "$leader" "('master', 'primary', 'leader')" || die "$leader is not writable leader"
    peer_replication_is_streaming "$leader" "$peer_slot_name" "$MAX_PREFLIGHT_LAG_BYTES" || \
      die "peer slot $peer_slot_name is absent, inactive, not streaming, or lag exceeds ${MAX_PREFLIGHT_LAG_BYTES} bytes"
    log "Fencing writable leader $leader and stopping this cluster."
    log "Stopping VIP $cluster_vip before the final replication catch-up."
    for host in "${nodes[@]}"; do
      stop_vip_node "$host"
    done
    # Pause failover while the old primary is being shut down.  If catch-up
    # times out, the VIP stays down and PostgreSQL is intentionally left up.
    patronictl pause --wait
    log "Waiting for peer slot $peer_slot_name to catch up within ${MAX_SWITCHOVER_LAG_BYTES} bytes."
    wait_for_peer_catchup "$leader" "$peer_slot_name" || \
      die "peer did not catch up within ${WAIT_SECONDS}s; VIP is stopped but PostgreSQL remains running"
    for host in "${nodes[@]}"; do
      stop_cluster_node "$host"
    done
    log 'Fence complete. On the standby cluster, run: ./dr_switchover.sh promote --conf <standby.conf>'
    ;;

  promote)
    # Planned promotion: the old primary must already be fenced, and this
    # standby must have replayed all WAL it received before becoming writable.
    [[ "$peer_vip" != "$cluster_vip" ]] || die "$conf: peer_cluster_vip must point to the other cluster"
    leader=$(leader_host) || die 'standby cluster has no reachable leader'
    role_is "$leader" "('standby_leader', 'standby leader')" || die "$leader is not a standby leader"
    assert_standby_cluster_config "$peer_vip" "$local_slot_name"
    assert_cluster_healthy standby
    standby_replay_is_ready "$leader" || die 'standby has not replayed all WAL it received or WAL replay is paused'
    if peer_accepts_database_connections "$peer_vip" "$peer_pg_port"; then
      die "former primary $peer_vip:$peer_pg_port still accepts connections; run fence there first"
    else
      peer_check_rc=$?
      [[ "$peer_check_rc" == 1 ]] || die 'unable to verify whether the former primary database port is fenced'
    fi
    log "Former primary VIP $peer_vip:$peer_pg_port is not accepting database connections."
    log "Promoting standby leader $leader. The old primary must already be fenced."
    # Removing standby_cluster is a Patroni DCS change.  Pause first so the
    # transition cannot race with an election; resume afterwards to let
    # Patroni elect the new writable leader.
    patronictl pause --wait
    ssh_root "$leader" "curl --fail --silent --show-error -X PATCH -H 'Content-Type: application/json' --data '{\"standby_cluster\": null}' http://127.0.0.1:8008/config" >/dev/null
    patronictl resume --wait
    new_primary=$(wait_for_primary_host) || die 'no cluster member became writable after promotion'
    log "Promotion elected $new_primary as new primary."
    complete_promotion
    log 'Promotion complete. On the former primary cluster, run: ./dr_switchover.sh rejoin --conf <former-primary.conf>'
    ;;

  emergency-promote)
    # Emergency path for an unreachable primary.  No network probe can prove
    # the old primary is down here, so isolation at the infrastructure layer
    # is an explicit prerequisite and is not attempted by this script.
    [[ "$peer_vip" != "$cluster_vip" ]] || die "$conf: peer_cluster_vip must point to the other cluster"
    leader=$(leader_host) || die 'standby cluster has no reachable leader'
    role_is "$leader" "('standby_leader', 'standby leader')" || die "$leader is not a standby leader"
    assert_standby_cluster_config "$peer_vip" "$local_slot_name"
    log "EMERGENCY promotion of $leader. Former primary VIP $peer_vip must already be isolated at the network, storage, host, or VIP layer."
    patronictl pause --wait
    ssh_root "$leader" "curl --fail --silent --show-error -X PATCH -H 'Content-Type: application/json' --data '{\"standby_cluster\": null}' http://127.0.0.1:8008/config" >/dev/null
    patronictl resume --wait
    new_primary=$(wait_for_primary_host) || die 'no cluster member became writable after emergency promotion'
    log "Emergency promotion elected $new_primary as new primary."
    complete_promotion
    log 'Emergency promotion complete. After the former primary cluster is available, run there: ./dr_switchover.sh rejoin --conf <former-primary.conf>'
    ;;

  finalize-promote)
    # Recovery path for a promotion that completed but was interrupted before
    # the return replication slot was created.
    primary=$(primary_host) || die 'this cluster has no writable leader to finalize'
    log "Completing promotion on existing primary $primary."
    complete_promotion
    log 'Promotion finalization complete. The former primary can now run rejoin.'
    ;;

  rejoin)
    # Rebuild the former primary from the new primary.  The upstream preflight
    # is intentionally before any local stop, DCS removal, or data-directory
    # rename so a failed connectivity/slot check is non-destructive.
    [[ "$peer_vip" != "$cluster_vip" ]] || die "$conf: peer_cluster_vip must point to the other cluster"
    # Re-running rejoin against an already healthy standby would otherwise
    # stop it and move its freshly seeded PGDATA again. Treat that state as a
    # successful no-op.
    if cluster_json | "$PYTHON" -c '
import json, sys
expected = int(sys.argv[1])
members = json.load(sys.stdin)
healthy = len(members) == expected and all(
    m.get("Role", "").lower() in ("replica", "standby leader", "standby_leader")
    and m.get("State", "").lower() in ("running", "streaming")
    for m in members)
raise SystemExit(0 if healthy else 1)' "${#nodes[@]}"; then
      assert_standby_cluster_config "$peer_vip" "$local_slot_name"
      log 'This cluster is already a healthy standby; rejoin is not needed.'
      exit 0
    fi
    scope=$actual_scope
    log "Verifying new primary $peer_vip:$peer_pg_port and preparing local rejoin slot $local_slot_name before local reset."
    prepare_upstream "$peer_vip" "$peer_pg_port" "$local_slot_name" || die 'new primary preflight failed; local data was not changed'
    log "Resetting this former primary and rebuilding it from $peer_vip:$peer_pg_port."
    # The fence phase must have stopped all nodes; repeat it defensively before
    # DCS removal because this phase may also follow emergency-promote.
    for host in "${nodes[@]}"; do
      stop_cluster_node "$host"
    done
    remove_cluster_from_dcs "$scope"
    # Keep timestamped copies of both config and data for forensic recovery.
    timestamp=$(date '+%Y%m%d_%H%M%S')
    for host in "${nodes[@]}"; do
      ssh_root "$host" bash -s -- "$patroni_conf" "$data_dir" "$peer_vip" "$peer_pg_port" "$local_slot_name" "$timestamp" <<'REMOTE'
set -Eeuo pipefail
config=$1 data_dir=$2 upstream_host=$3 upstream_port=$4 slot=$5 stamp=$6
cp -a "$config" "${config}.before_dr_${stamp}"
tmp=$(mktemp)
awk -v host="$upstream_host" -v port="$upstream_port" -v slot="$slot" '
  # Replace any old standby_cluster block and insert the new upstream below
  # bootstrap.dcs, immediately before postgresql.  The basebackup method then
  # lets Patroni initialize the freshly created data directory.
  /^    standby_cluster:/ { skipping=1; next }
  skipping && /^    [^ ]/ { skipping=0 }
  skipping { next }
  /^    postgresql:/ {
    print "    standby_cluster:"
    print "      host: " host
    print "      port: " port
    print "      primary_slot_name: " slot
    print "      create_replica_methods:"
    print "      - basebackup"
  }
  { print }
' "$config" > "$tmp"
install -o openpie -g openpie -m 600 "$tmp" "$config"
rm -f "$tmp"
if [ -e "$data_dir" ]; then mv "$data_dir" "${data_dir}.before_dr_${stamp}"; fi
install -d -o openpie -g openpie -m 700 "$data_dir"
systemctl start patroni
systemctl start tp_vip 2>/dev/null || true
REMOTE
    done
    log "Waiting for this cluster to initialize as a standby."
    elapsed=0
    while ((elapsed < WAIT_SECONDS)); do
      if cluster_json | "$PYTHON" -c '
import json,sys
expected=int(sys.argv[1])
members=json.load(sys.stdin)
healthy=len(members) == expected and all(
    m.get("Role", "").lower() in ("replica", "standby leader", "standby_leader")
    and m.get("State", "").lower() in ("running", "streaming")
    for m in members)
raise SystemExit(0 if healthy else 1)' "${#nodes[@]}"; then
        log 'Rejoin complete.'
        exit 0
      fi
      sleep 2
      elapsed=$((elapsed + 2))
    done
    die "former primary did not initialize as standby within ${WAIT_SECONDS}s"
    ;;
esac
