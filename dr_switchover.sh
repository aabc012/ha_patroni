#!/usr/bin/env bash
# Execute one DR cutover phase on one Patroni cluster only.

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./dr_switchover.sh fence   --conf <current-primary.conf> --handoff <file>
  ./dr_switchover.sh promote --conf <current-standby.conf> --handoff <file>
  ./dr_switchover.sh rejoin  --conf <former-primary.conf> --handoff <file>
  ./dr_switchover.sh emergency-promote --conf <current-standby.conf> \
    --former-primary-conf <former-primary.conf> --handoff <file>

Run each phase from a host that can SSH to every node in that phase's cluster.
The handoff file is copied manually from primary -> standby after fence, then
from standby -> former primary after promote. No cross-cluster SSH is used.

emergency-promote is for an unreachable primary. It does not contact or fence
the former primary; isolate that primary at the network/storage/VIP layer first.

Optional environment variables:
  PATRONICTL=/path/to/patronictl   (default: /opt/miniconda3/envs/py311/bin/patronictl)
  PSQL=/path/to/psql               (default: /opt/pieclouddb-tp/bin/psql)
  BACKUP_ROOT=/path                (default: /data/patroni-dr-backup)
  WAIT_SECONDS=180                 (default: 180)
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
confirm() {
  local word=$1 answer
  read -r -p "Type $word to continue: " answer
  [[ "$answer" == "$word" ]] || die 'operation cancelled'
}

stage=${1:-}
[[ -n "$stage" ]] && shift || true
if [[ "$stage" == -h || "$stage" == --help ]]; then
  usage
  exit 0
fi
conf=''
handoff=''
former_primary_conf=''
while (($#)); do
  case "$1" in
    --conf) conf=${2:-}; shift 2 ;;
    --handoff) handoff=${2:-}; shift 2 ;;
    --former-primary-conf) former_primary_conf=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done
[[ "$stage" == fence || "$stage" == promote || "$stage" == rejoin || "$stage" == emergency-promote ]] || { usage >&2; exit 2; }
[[ -n "$conf" && -r "$conf" ]] || die '--conf must be a readable file'
[[ -n "$handoff" ]] || die '--handoff is required'
if [[ "$stage" == emergency-promote ]]; then
  [[ -n "$former_primary_conf" && -r "$former_primary_conf" ]] || die 'emergency-promote requires a readable --former-primary-conf'
fi

PATRONICTL=${PATRONICTL:-/opt/miniconda3/envs/py311/bin/patronictl}
PSQL=${PSQL:-/opt/pieclouddb-tp/bin/psql}
BACKUP_ROOT=${BACKUP_ROOT:-/data/patroni-dr-backup}
WAIT_SECONDS=${WAIT_SECONDS:-180}

unset ip_list host_list tp_data vip primary_cluster_pg_port primary_slot_name primary_cluster_pg_password superuser_password
# shellcheck disable=SC1090
source "$conf"
IFS=',' read -r -a hosts <<< "${host_list:?missing host_list in $conf}"
IFS=',' read -r -a ips <<< "${ip_list:?missing ip_list in $conf}"
((${#hosts[@]} == ${#ips[@]})) || die "$conf: ip_list and host_list differ in length"
data_dir=${tp_data:?missing tp_data in $conf}
cluster_vip=${vip:?missing vip in $conf}
pg_port=${primary_cluster_pg_port:-5432}
slot_name=${primary_slot_name:-dr_standby}
pg_password=${superuser_password:-${primary_cluster_pg_password:-openpie}}
ha_dir=$(awk -F= '/^[[:space:]]*(export[[:space:]]+)?ha_tp_dir=/{gsub(/["[:space:]]/, "", $2); print $2; exit}' "$conf")
ha_dir=${ha_dir:-/opt/ha_pieclouddb_tp}
patroni_conf="$ha_dir/patroni/patroni.yml"
control_host=${hosts[0]}

former_primary_values() {
  local old_conf=$1 old_vip old_slot old_scope
  old_vip=$(awk -F= '/^[[:space:]]*(export[[:space:]]+)?vip=/{gsub(/["[:space:]]/, "", $2); print $2; exit}' "$old_conf")
  old_slot=$(awk -F= '/^[[:space:]]*(export[[:space:]]+)?primary_slot_name=/{gsub(/["[:space:]]/, "", $2); print $2; exit}' "$old_conf")
  old_scope=$(awk -F= '/^[[:space:]]*(export[[:space:]]+)?patroni_scope=/{gsub(/["[:space:]]/, "", $2); print $2; exit}' "$old_conf")
  old_scope=${old_scope:-pieclouddb-tp}
  [[ -n "$old_vip" ]] || die "$old_conf: missing vip"
  old_slot=${old_slot:-dr_standby}
  safe_value "$old_vip"; safe_value "$old_slot"; safe_value "$old_scope"
  printf '%s %s %s\n' "$old_vip" "$old_slot" "$old_scope"
}

ssh_root() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$@"; }
patronictl() { ssh_root "$control_host" "$PATRONICTL -c '$patroni_conf' $*"; }
cluster_json() { patronictl list -f json; }
cluster_scope() { ssh_root "$control_host" "awk -F ': *' '/^scope:/ {print \$2; exit}' '$patroni_conf'"; }
leader_host() {
  cluster_json | python3 -c '
import json, sys
for member in json.load(sys.stdin):
    if member.get("Role", "").lower() in ("leader", "primary", "master"):
        print(member["Host"]); break
else: raise SystemExit("No leader found")'
}
role_is() {
  local host=$1 expected=$2
  ssh_root "$host" 'curl --fail --silent --show-error http://127.0.0.1:8008/patroni' | \
    python3 -c "import json,sys; raise SystemExit(0 if json.load(sys.stdin).get('role') in ${expected} else 1)"
}
wait_for_role() {
  local host=$1 expected=$2 elapsed=0
  while ((elapsed < WAIT_SECONDS)); do
    if role_is "$host" "$expected"; then return 0; fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}
safe_value() { [[ "$1" =~ ^[a-zA-Z0-9._:/-]+$ ]] || die "unsafe handoff value: $1"; }
handoff_value() {
  local key=$1 file=$2 value
  [[ -r "$file" ]] || die "handoff file is not readable: $file"
  value=$(awk -F= -v key="$key" '$1 == key {print substr($0, length(key) + 2); exit}' "$file")
  [[ -n "$value" ]] || die "handoff lacks $key"
  safe_value "$value"
  printf '%s' "$value"
}
write_handoff() {
  local file=$1 source_scope=$2 source_slot=$3 backup=$4 source_vip=$5 new_vip=${6:-} new_port=${7:-}
  safe_value "$source_scope"; safe_value "$source_slot"; safe_value "$backup"
  safe_value "$source_vip"
  [[ -z "$new_vip" ]] || safe_value "$new_vip"
  [[ -z "$new_port" ]] || safe_value "$new_port"
  umask 077
  local temp_file="${file}.tmp.$$"
  {
    printf 'DR_HANDOFF_VERSION=1\n'
    printf 'DR_SOURCE_SCOPE=%s\n' "$source_scope"
    printf 'DR_SOURCE_SLOT=%s\n' "$source_slot"
    printf 'DR_LEADER_BACKUP=%s\n' "$backup"
    printf 'DR_SOURCE_VIP=%s\n' "$source_vip"
    [[ -z "$new_vip" ]] || printf 'DR_NEW_PRIMARY_VIP=%s\n' "$new_vip"
    [[ -z "$new_port" ]] || printf 'DR_NEW_PRIMARY_PORT=%s\n' "$new_port"
  } > "$temp_file"
  mv -f "$temp_file" "$file"
  chmod 600 "$file"
}

for host in "${hosts[@]}"; do
  ssh_root "$host" true || die "root SSH unavailable in this cluster: $host"
done

case "$stage" in
  fence)
    scope=$(cluster_scope)
    [[ -n "$scope" ]] || die 'unable to obtain Patroni scope'
    leader=$(leader_host) || die 'current primary cluster has no reachable leader'
    role_is "$leader" "('master', 'primary', 'leader')" || die "$leader is not writable leader"
    timestamp=$(date '+%Y%m%d_%H%M%S')
    backup_dir="$BACKUP_ROOT/${scope}_${timestamp}_${leader}"
    log "Fencing writable leader $leader and stopping this cluster."
    confirm FENCE
    patronictl pause --wait
    for host in "${hosts[@]}"; do
      ssh_root "$host" 'systemctl stop tp_vip 2>/dev/null || true; systemctl stop patroni'
    done
    log "Backing up former leader data directory to $backup_dir."
    ssh_root "$leader" bash -s -- "$data_dir" "$backup_dir" <<'REMOTE'
set -Eeuo pipefail
data_dir=$1 backup_dir=$2
test -d "$data_dir"
mkdir -p "$backup_dir"
tar --xattrs --acls -C "$(dirname "$data_dir")" -czf "$backup_dir/$(basename "$data_dir").tar.gz" "$(basename "$data_dir")"
sha256sum "$backup_dir/$(basename "$data_dir").tar.gz" > "$backup_dir/$(basename "$data_dir").tar.gz.sha256"
REMOTE
    write_handoff "$handoff" "$scope" "$slot_name" "$backup_dir" "$cluster_vip"
    log "Fence complete. Copy $handoff to the standby cluster and run: dr_switchover.sh promote --conf <standby.conf> --handoff <file>"
    ;;

  promote)
    source_slot=$(handoff_value DR_SOURCE_SLOT "$handoff")
    leader=$(leader_host) || die 'standby cluster has no reachable leader'
    role_is "$leader" "('standby_leader', 'standby leader')" || die "$leader is not a standby leader"
    log "Promoting standby leader $leader. The old primary must already be fenced."
    confirm PROMOTE
    patronictl pause --wait
    ssh_root "$leader" "curl --fail --silent --show-error -X PATCH -H 'Content-Type: application/json' --data '{\"standby_cluster\": null}' http://127.0.0.1:8008/config" >/dev/null
    patronictl resume --wait
    wait_for_role "$leader" "('master', 'primary', 'leader')" || die "leader $leader did not become writable"
    log "Creating replication slot $source_slot on the new primary."
    ssh_root "$leader" env "PGPASSWORD=$pg_password" "$PSQL" -h 127.0.0.1 -U openpie -d postgres -v ON_ERROR_STOP=1 \
      -c "SELECT pg_create_physical_replication_slot('${source_slot}') WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = '${source_slot}');" >/dev/null
    write_handoff "$handoff" "$(handoff_value DR_SOURCE_SCOPE "$handoff")" "$source_slot" "$(handoff_value DR_LEADER_BACKUP "$handoff")" "$(handoff_value DR_SOURCE_VIP "$handoff")" "$cluster_vip" "$pg_port"
    log "Promotion complete. Copy $handoff back to the former primary cluster and run: dr_switchover.sh rejoin --conf <former-primary.conf> --handoff <file>"
    ;;

  emergency-promote)
    read -r former_vip former_slot former_scope < <(former_primary_values "$former_primary_conf")
    leader=$(leader_host) || die 'standby cluster has no reachable leader'
    role_is "$leader" "('standby_leader', 'standby leader')" || die "$leader is not a standby leader"
    log "EMERGENCY promotion of $leader. Confirm former primary VIP $former_vip is fenced outside this script."
    confirm EMERGENCY
    patronictl pause --wait
    ssh_root "$leader" "curl --fail --silent --show-error -X PATCH -H 'Content-Type: application/json' --data '{\"standby_cluster\": null}' http://127.0.0.1:8008/config" >/dev/null
    patronictl resume --wait
    wait_for_role "$leader" "('master', 'primary', 'leader')" || die "leader $leader did not become writable"
    log "Creating replication slot $former_slot on emergency primary."
    ssh_root "$leader" env "PGPASSWORD=$pg_password" "$PSQL" -h 127.0.0.1 -U openpie -d postgres -v ON_ERROR_STOP=1 \
      -c "SELECT pg_create_physical_replication_slot('${former_slot}') WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = '${former_slot}');" >/dev/null
    write_handoff "$handoff" "$former_scope" "$former_slot" unavailable "$former_vip" "$cluster_vip" "$pg_port"
    log "Emergency promotion complete. When the former primary is reachable, copy $handoff there and run: dr_switchover.sh rejoin --conf <former-primary.conf> --handoff <file>"
    ;;

  rejoin)
    source_scope=$(handoff_value DR_SOURCE_SCOPE "$handoff")
    source_vip=$(handoff_value DR_SOURCE_VIP "$handoff")
    new_vip=$(handoff_value DR_NEW_PRIMARY_VIP "$handoff")
    new_port=$(handoff_value DR_NEW_PRIMARY_PORT "$handoff")
    source_slot=$(handoff_value DR_SOURCE_SLOT "$handoff")
    scope=$(cluster_scope)
    [[ "$scope" == "$source_scope" ]] || die "handoff scope $source_scope does not match this cluster ($scope)"
    [[ "$cluster_vip" == "$source_vip" ]] || die "handoff source VIP $source_vip does not match this cluster ($cluster_vip)"
    log "Resetting this former primary and rebuilding it from $new_vip:$new_port."
    confirm REJOIN
    # The fence phase must have stopped all nodes; repeat it defensively before DCS removal.
    for host in "${hosts[@]}"; do
      ssh_root "$host" 'systemctl stop tp_vip 2>/dev/null || true; systemctl stop patroni 2>/dev/null || true'
    done
    patronictl remove "$scope" --force
    timestamp=$(date '+%Y%m%d_%H%M%S')
    for host in "${hosts[@]}"; do
      ssh_root "$host" bash -s -- "$patroni_conf" "$data_dir" "$new_vip" "$new_port" "$source_slot" "$timestamp" <<'REMOTE'
set -Eeuo pipefail
config=$1 data_dir=$2 upstream_host=$3 upstream_port=$4 slot=$5 stamp=$6
cp -a "$config" "${config}.before_dr_${stamp}"
tmp=$(mktemp)
awk -v host="$upstream_host" -v port="$upstream_port" -v slot="$slot" '
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
      if cluster_json | python3 -c '
import json,sys
members=json.load(sys.stdin)
raise SystemExit(0 if members and all(m.get("Role", "").lower() in ("replica", "standby leader", "standby_leader") for m in members) else 1)'; then
        log 'Rejoin complete.'
        exit 0
      fi
      sleep 2
      elapsed=$((elapsed + 2))
    done
    die "former primary did not initialize as standby within ${WAIT_SECONDS}s"
    ;;
esac
