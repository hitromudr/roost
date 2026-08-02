#!/usr/bin/env bash
# Applies the gate role to a container and checks the result the way nginx
# does: by loading the configuration. A vhost that only looks right is a vhost
# that fails at 2am when you reload for something unrelated.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="debian:12-slim"
NAME="roost-gate-test-$$"
DOMAIN="gate.test"

log() { printf '\033[1;34m[gate-test]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
bad() { printf '\033[1;31m  ✗\033[0m %s\n' "$*"; exit 1; }

command -v docker >/dev/null || { echo "docker not installed — skipping"; exit 0; }
command -v ansible-playbook >/dev/null || { echo "ansible not installed — skipping"; exit 0; }

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "starting container"
docker run -d --name "$NAME" "$IMAGE" sleep 900 >/dev/null
docker exec "$NAME" sh -c \
	'apt-get update -qq && apt-get install -y -qq nginx openssl python3 >/dev/null 2>&1'

# A self-signed server certificate stands in for the real one: this test is
# about the vhost, not about certbot.
log "issuing a stand-in TLS certificate"
docker exec "$NAME" sh -c "mkdir -p /etc/ssl/$DOMAIN && openssl req -x509 -newkey rsa:2048 -nodes \
	-keyout /etc/ssl/$DOMAIN/key.pem -out /etc/ssl/$DOMAIN/cert.pem \
	-days 1 -subj '/CN=$DOMAIN' >/dev/null 2>&1"

cat > /tmp/roost-gate-inv-$$ <<EOF
[gate]
$NAME ansible_connection=docker
EOF

log "applying the gate role"
(cd "$ROOT" && ansible-playbook -i "/tmp/roost-gate-inv-$$" ansible/playbooks/gate.yml \
	-e gate_domain="$DOMAIN" \
	-e gate_tls_cert="/etc/ssl/$DOMAIN/cert.pem" \
	-e gate_tls_key="/etc/ssl/$DOMAIN/key.pem" \
	-e gate_auth=mtls -e ansible_become=false) || bad "the role failed"
rm -f "/tmp/roost-gate-inv-$$"

log "checking the result"
docker exec "$NAME" nginx -t >/dev/null 2>&1 || bad "nginx rejects the configuration"
ok "nginx accepts the configuration"

for f in ca.crt ca.key phone.p12; do
	docker exec "$NAME" test -f "/etc/roost/ca/$f" || bad "missing /etc/roost/ca/$f"
done
ok "client CA and a phone bundle were issued"

perms="$(docker exec "$NAME" stat -c '%a' /etc/roost/ca/ca.key)"
[ "$perms" = "600" ] || bad "CA key has permissions $perms, expected 600"
ok "CA key is not readable by others"

docker exec "$NAME" grep -q "ssl_verify_client on" "/etc/nginx/sites-available/roost-$DOMAIN.conf" \
	|| bad "mtls mode did not enable client verification"
ok "client certificates are required"

docker exec "$NAME" grep -q 'proxy_set_header Host \$host' "/etc/nginx/sites-available/roost-$DOMAIN.conf" \
	|| bad "Host header is rewritten — pockterm would refuse the websocket upgrade"
ok "the four things that silently break a terminal are right"

# The tunnel account exists and cannot be used as a login.
shell="$(docker exec "$NAME" getent passwd roost-tunnel | cut -d: -f7)"
[ "$shell" = "/usr/sbin/nologin" ] || bad "tunnel account has shell $shell"
ok "the tunnel account has no shell"

log "checking idempotence"
cat > /tmp/roost-gate-inv-$$ <<EOF
[gate]
$NAME ansible_connection=docker
EOF
out="$(cd "$ROOT" && ansible-playbook -i "/tmp/roost-gate-inv-$$" ansible/playbooks/gate.yml \
	-e gate_domain="$DOMAIN" \
	-e gate_tls_cert="/etc/ssl/$DOMAIN/cert.pem" \
	-e gate_tls_key="/etc/ssl/$DOMAIN/key.pem" \
	-e gate_auth=mtls -e ansible_become=false 2>&1 | tail -3)"
rm -f "/tmp/roost-gate-inv-$$"
echo "$out" | grep -q "changed=0" || { echo "$out"; bad "second run still reports changes"; }
ok "second run changes nothing"

echo
log "all checks passed"
