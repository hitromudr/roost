#!/usr/bin/env bash
# Proves the egress policy in a throwaway container: a process in the sandbox
# group must reach a local service and fail to reach anything else.
#
# The bats suite checks which rules get generated; this checks that those
# rules do what the README claims. Needs docker and NET_ADMIN.
#
#   tests/integration/egress_container.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="debian:12-slim"
NAME="roost-egress-test-$$"

log() { printf '\033[1;34m[egress-test]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
bad() { printf '\033[1;31m  ✗\033[0m %s\n' "$*"; exit 1; }

command -v docker >/dev/null || { echo "docker not installed — skipping"; exit 0; }

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "starting container"
docker run -d --name "$NAME" --cap-add NET_ADMIN "$IMAGE" sleep 600 >/dev/null

log "installing iptables, curl, python"
docker exec "$NAME" sh -c \
	'apt-get update -qq && apt-get install -y -qq iptables curl python3 >/dev/null 2>&1'

docker cp "$ROOT/ansible/roles/egress_sandbox/files/egress-firewall" "$NAME:/usr/local/sbin/"
docker exec "$NAME" chmod +x /usr/local/sbin/egress-firewall

log "creating the sandbox group and a local service"
docker exec "$NAME" groupadd -g 4242 agent-sandbox
docker exec -d "$NAME" sh -c 'cd /tmp && python3 -m http.server 8129'
sleep 2

# Before the policy: the group can reach the outside world. Establishing this
# first matters — otherwise a failure afterwards could just be a container
# with no network at all.
log "baseline, before any rules"
if docker exec "$NAME" sg agent-sandbox -c 'curl -sS -m 5 -o /dev/null http://deb.debian.org/'; then
	ok "outbound works before the policy"
else
	echo "  container has no outbound network — the test cannot prove anything"
	exit 0
fi

log "applying the pinned profile"
docker exec -e EGRESS_GROUP=agent-sandbox -e EGRESS_GID=4242 -e EGRESS_PROFILE=pinned \
	"$NAME" /usr/local/sbin/egress-firewall apply

log "checking the policy"
if docker exec "$NAME" sg agent-sandbox -c 'curl -sS -m 5 -o /dev/null http://deb.debian.org/' 2>/dev/null; then
	bad "sandboxed process still reaches the internet"
fi
ok "direct egress is rejected for the group"

if docker exec "$NAME" sg agent-sandbox -c 'curl -sS -m 5 -o /dev/null http://127.0.0.1:8129/'; then
	ok "the local proxy is still reachable"
else
	bad "loopback is blocked too — the agent would have no way out at all"
fi

# Everyone else must be unaffected: the policy is per-group, not per-machine.
if docker exec "$NAME" curl -sS -m 5 -o /dev/null http://deb.debian.org/; then
	ok "processes outside the group are unaffected"
else
	bad "the policy leaked to the whole machine"
fi

log "checking idempotence"
before="$(docker exec "$NAME" iptables -S OUTPUT | wc -l)"
docker exec -e EGRESS_GROUP=agent-sandbox -e EGRESS_GID=4242 -e EGRESS_PROFILE=pinned \
	"$NAME" /usr/local/sbin/egress-firewall apply
after="$(docker exec "$NAME" iptables -S OUTPUT | wc -l)"
[ "$before" = "$after" ] || bad "re-applying added duplicate rules ($before → $after)"
ok "re-applying changes nothing"

log "checking clear"
docker exec -e EGRESS_GROUP=agent-sandbox -e EGRESS_GID=4242 -e EGRESS_PROFILE=pinned \
	"$NAME" /usr/local/sbin/egress-firewall clear
left="$(docker exec "$NAME" iptables -S OUTPUT | grep -c agent-sandbox || true)"
[ "$left" = "0" ] || bad "$left rules survived clear"
if docker exec "$NAME" sg agent-sandbox -c 'curl -sS -m 5 -o /dev/null http://deb.debian.org/'; then
	ok "egress restored after clear"
else
	bad "clear left the group cut off"
fi


# --- teardown -----------------------------------------------------------
# The clear path above is the script's own; this checks the state a user is
# left in: no rules, no tag, and egress working again for everyone.
log "checking that nothing is left behind"
docker exec -e EGRESS_GROUP=agent-sandbox -e EGRESS_GID=4242 -e EGRESS_PROFILE=pinned \
	"$NAME" /usr/local/sbin/egress-firewall apply
docker exec "$NAME" rm -f /usr/local/sbin/egress-firewall

# Simulating the teardown playbook's order: rules are cleared before the
# script goes. Re-add it to clear, then remove for good.
docker cp "$ROOT/ansible/roles/egress_sandbox/files/egress-firewall" "$NAME:/usr/local/sbin/"
docker exec "$NAME" chmod +x /usr/local/sbin/egress-firewall
docker exec -e EGRESS_GROUP=agent-sandbox -e EGRESS_GID=4242 -e EGRESS_PROFILE=pinned \
	"$NAME" /usr/local/sbin/egress-firewall clear
docker exec "$NAME" rm -f /usr/local/sbin/egress-firewall

remaining="$(docker exec "$NAME" iptables -S OUTPUT | grep -c agent-sandbox || true)"
[ "$remaining" = "0" ] || bad "$remaining rules left after teardown"
remaining6="$(docker exec "$NAME" ip6tables -S OUTPUT | grep -c agent-sandbox || true)"
[ "$remaining6" = "0" ] || bad "$remaining6 ipv6 rules left after teardown"
ok "no rules left, in either address family"

if docker exec "$NAME" sg agent-sandbox -c 'curl -sS -m 5 -o /dev/null http://deb.debian.org/'; then
	ok "the machine is back to how it started"
else
	bad "teardown left the group without egress"
fi

echo
log "all checks passed"
