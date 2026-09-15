#!/usr/bin/env bash
# Update a CoreDNS hosts entry and restart workloads that consume it.

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./update_coredns_and_restart.sh <new-ip> [domain]

Examples:
  ./update_coredns_and_restart.sh 10.24.11.221
  ./update_coredns_and_restart.sh 10.24.11.221 tp.patroni.internal

The script uses the current kubectl context and requires permission to update
the kube-system/coredns ConfigMap and restart the listed Deployments.
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

[[ ${1:-} != "-h" && ${1:-} != "--help" ]] || { usage; exit 0; }
new_ip=${1:-}
domain=${2:-tp.example.internal}
[[ -n "$new_ip" ]] || { usage >&2; exit 2; }
[[ $# -le 2 ]] || die 'too many arguments'

# Validate values before putting them into a shell or Python expression.
python3 - "$new_ip" "$domain" <<'PY'
import ipaddress
import re
import sys

try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit("new-ip must be a valid IPv4 or IPv6 address")

if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", sys.argv[2]):
    raise SystemExit("domain must be a DNS name")
PY

command -v kubectl >/dev/null 2>&1 || die 'kubectl is required'
command -v python3 >/dev/null 2>&1 || die 'python3 is required'
kubectl version --client >/dev/null 2>&1 || die 'kubectl is not usable'

log "Updating kube-system/coredns: $domain -> $new_ip"
config_json=$(kubectl -n kube-system get configmap coredns -o json) || die 'unable to read kube-system/coredns'
config_file=$(mktemp)
trap 'rm -f "$config_file"' EXIT
printf '%s\n' "$config_json" > "$config_file"
updated_json=$(python3 - "$new_ip" "$domain" "$config_file" <<'PY'
import json
import re
import sys

new_ip, domain, config_file = sys.argv[1:]
with open(config_file, encoding="utf-8") as stream:
    obj = json.load(stream)
corefile = (obj.get("data") or {}).get("Corefile")
if corefile is None:
    raise SystemExit("coredns ConfigMap does not contain data.Corefile")

# Replace the address on every hosts record containing this exact domain.
domain_re = re.escape(domain)
pattern = re.compile(rf"^(?P<indent>\s*)\S+(?P<separator>\s+){domain_re}(?P<rest>(?:\s+.*)?$)", re.MULTILINE)
corefile, replacements = pattern.subn(rf"\g<indent>{new_ip}\g<separator>{domain}\g<rest>", corefile)
if replacements == 0:
    raise SystemExit(f"no Corefile hosts record found for domain {domain}")

obj["data"]["Corefile"] = corefile
print(json.dumps(obj, separators=(",", ":")))
PY
) || die 'failed to update Corefile content'

printf '%s\n' "$updated_json" | kubectl -n kube-system replace -f - >/dev/null || \
  die 'failed to replace kube-system/coredns ConfigMap'

log 'Restarting CoreDNS and waiting for rollout'
kubectl -n kube-system rollout restart deployment/coredns
kubectl -n kube-system rollout status deployment/coredns

restart_and_wait() {
  local namespace=$1 deployment=$2
  log "Restarting $namespace/$deployment and waiting for rollout"
  kubectl -n "$namespace" rollout restart "deployment/$deployment"
  kubectl -n "$namespace" rollout status "deployment/$deployment"
}

restart_and_wait openpie-account ops-account
restart_and_wait openpie-ops timertask
restart_and_wait openpie-polaris authzutil

log "Completed: $domain now resolves to $new_ip"
