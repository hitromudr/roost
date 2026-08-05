#!/usr/bin/env bash
# Proves the client-certificate lock in a throwaway container: without a
# certificate the terminal is refused, with one it is reached, a revoked one is
# refused again, and the enrolment path stays open to the phone that has none yet.
#
# The bats suite covers what the authority produces; this covers whether nginx
# then does what the vhost claims — and it does it with the real template and the
# real script rather than with a copy of them, because a copy is what drifts.
#
#   tests/integration/mtls_container.sh
#
# Needs docker, ansible (to render the template) and openssl.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="nginx:1.27-alpine"
NAME="roost-mtls-test-$$"
WORK="$(mktemp -d)"
PORT=""

log() { printf '\033[1;34m[mtls-test]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
bad() { printf '\033[1;31m  ✗\033[0m %s\n' "$*"; exit 1; }

command -v docker >/dev/null || { echo "docker not installed — skipping"; exit 0; }
command -v ansible >/dev/null || { echo "ansible not installed — skipping"; exit 0; }
command -v openssl >/dev/null || { echo "openssl not installed — skipping"; exit 0; }

cleanup() {
	docker rm -f "$NAME" >/dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT

# --- the authority, from roost's own script ------------------------------
log "creating the authority and one device's certificate"
export ROOST_CA_DIR="$WORK/ca"
mkdir -p "$ROOST_CA_DIR"
CA="$ROOT/ansible/roles/expose/files/roost-ca"
"$CA" init >/dev/null
issued="$("$CA" issue phone)"
p12="$(sed -n 's/^file=//p' <<<"$issued")"
pass="$(sed -n 's/^password=//p' <<<"$issued")"
# What a phone imports is the bundle; what curl needs is the pair inside it, so
# the bundle is unpacked here — which also proves it can be.
openssl pkcs12 -in "$p12" -passin "pass:$pass" -nokeys -clcerts -out "$WORK/phone.crt" 2>/dev/null
openssl pkcs12 -in "$p12" -passin "pass:$pass" -nocerts -nodes -out "$WORK/phone.key" 2>/dev/null
if [ ! -s "$WORK/phone.crt" ] || [ ! -s "$WORK/phone.key" ]; then
	bad "the device's bundle did not open"
fi
ok "authority, and a bundle that opens with the password it printed"

# A second device, to be revoked later. Issued now so the test does not depend on
# the order nginx caches anything in.
issued2="$("$CA" issue laptop)"
p12b="$(sed -n 's/^file=//p' <<<"$issued2")"
passb="$(sed -n 's/^password=//p' <<<"$issued2")"
openssl pkcs12 -in "$p12b" -passin "pass:$passb" -nokeys -clcerts -out "$WORK/laptop.crt" 2>/dev/null
openssl pkcs12 -in "$p12b" -passin "pass:$passb" -nocerts -nodes -out "$WORK/laptop.key" 2>/dev/null

# --- a server certificate, so there is TLS to put the lock behind -------
log "issuing a server certificate for localhost"
mkdir -p "$WORK/certs/localhost"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=localhost" \
	-addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
	-keyout "$WORK/certs/localhost/privkey.pem" \
	-out "$WORK/certs/localhost/fullchain.pem" 2>/dev/null

# --- the vhost, rendered from the template that a stand gets ------------
log "rendering the vhost from the role's own template"
mkdir -p "$WORK/conf.d" "$WORK/enroll" "$WORK/acme"
cat > "$WORK/vars.json" <<JSON
{
  "expose_client_auth": "mtls",
  "expose_resolved_host": "localhost",
  "expose_tls_port": 8443,
  "expose_upstream": "127.0.0.1:8130",
  "expose_cert_root": "/etc/nginx/certs",
  "expose_ca_dir": "/etc/nginx/ca",
  "expose_enroll_dir": "/var/www/roost-enroll",
  "expose_webroot": "/var/www/roost-acme",
  "expose_cert_present": true,
  "expose_terminal_user": "tester",
  "ansible_managed": "rendered by tests/integration/mtls_container.sh"
}
JSON
ansible localhost -m ansible.builtin.template -c local \
	-a "src=$ROOT/ansible/roles/expose/templates/vhost.conf.j2 dest=$WORK/conf.d/roost-terminal.conf mode=0644" \
	-e "@$WORK/vars.json" >/dev/null || bad "the template did not render"
grep -q "ssl_verify_client" "$WORK/conf.d/roost-terminal.conf" ||
	bad "the rendered vhost has no client verification in it"
ok "vhost rendered, and it asks for a client certificate"

# The thing being protected. A container has no pockterm in it, so the upstream
# is a server that says one word — what is under test is the lock, not the
# terminal.
cat > "$WORK/conf.d/upstream.conf" <<'CONF'
server {
    listen 127.0.0.1:8130;
    location / { default_type text/plain; return 200 "terminal\n"; }
}
CONF

# --- the container -------------------------------------------------------
log "starting nginx"
docker run -d --name "$NAME" -p 127.0.0.1:0:8443 \
	-v "$WORK/conf.d:/etc/nginx/conf.d:ro" \
	-v "$WORK/certs:/etc/nginx/certs:ro" \
	-v "$WORK/ca:/etc/nginx/ca:ro" \
	-v "$WORK/enroll:/var/www/roost-enroll:ro" \
	-v "$WORK/acme:/var/www/roost-acme:ro" \
	"$IMAGE" >/dev/null
PORT="$(docker port "$NAME" 8443/tcp | head -1 | sed 's/.*://')"
[ -n "$PORT" ] || bad "the container published no port"

for _ in $(seq 1 50); do
	if curl -sk --max-time 2 "https://127.0.0.1:$PORT/" >/dev/null 2>&1; then break; fi
	sleep 0.2
done
docker exec "$NAME" nginx -t >/dev/null 2>&1 || bad "nginx rejected the rendered configuration: $(docker logs "$NAME" 2>&1 | tail -3)"
ok "nginx accepted it"

ask() {
	# --resolve rather than -k alone: the point of the exercise is a client
	# certificate, and a server name that does not match would fail for the
	# wrong reason.
	curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
		--cacert "$WORK/certs/localhost/fullchain.pem" \
		--resolve "localhost:$PORT:127.0.0.1" "$@" "https://localhost:$PORT/"
}

log "asking without a certificate"
code="$(ask)"
[ "$code" = 403 ] || bad "expected 403 without a certificate, got $code"
ok "the terminal is refused without one"

log "asking with the device's certificate"
code="$(ask --cert "$WORK/phone.crt" --key "$WORK/phone.key")"
[ "$code" = 200 ] || bad "expected 200 with the certificate, got $code"
ok "the terminal is reached with one"

log "asking with a certificate from somewhere else"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=stranger" \
	-keyout "$WORK/stranger.key" -out "$WORK/stranger.crt" 2>/dev/null
code="$(ask --cert "$WORK/stranger.crt" --key "$WORK/stranger.key")"
# Two different refusals, and it is worth knowing which is which. No certificate
# at all reaches the location and gets the vhost's own 403 with a sentence about
# `roost enroll`. A certificate this authority never signed does not get that
# far: under `ssl_verify_client optional` nginx fails the verification itself and
# answers 400 before any location is chosen.
#
# `optional` and not `optional_no_ca` for exactly that reason — no_ca would hand
# the decision to the vhost and a nicer message with it, but it also stops nginx
# checking the certificate against the authority *and its revocation list*, which
# is the whole mechanism.
case "$code" in
	400 | 403) ok "somebody else's certificate is not a way in (HTTP $code)" ;;
	*) bad "expected a refusal for a certificate this authority never signed, got $code" ;;
esac

log "the enrolment path, for a phone that has none yet"
echo "not really a bundle" > "$WORK/enroll/testfile.p12"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
	--cacert "$WORK/certs/localhost/fullchain.pem" \
	--resolve "localhost:$PORT:127.0.0.1" \
	"https://localhost:$PORT/roost-enroll/testfile.p12")"
[ "$code" = 200 ] || bad "a device with no certificate cannot collect one: got $code"
ok "the bundle can be collected without a certificate"

log "and nothing else from that directory"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
	--cacert "$WORK/certs/localhost/fullchain.pem" \
	--resolve "localhost:$PORT:127.0.0.1" \
	"https://localhost:$PORT/roost-enroll/")"
[ "$code" = 403 ] || [ "$code" = 404 ] || bad "the enrolment directory lists itself: got $code"
ok "the directory itself is not browsable"

# Asked before as well as after, because "refused" on its own proves nothing
# about revocation: a certificate that was never a way in would also be refused,
# and the test would pass while the revocation list did nothing.
log "the second device, before it is revoked"
code="$(ask --cert "$WORK/laptop.crt" --key "$WORK/laptop.key")"
[ "$code" = 200 ] || bad "the second device was not a way in to begin with: got $code"
ok "it gets in"

log "revoking it"
"$CA" revoke laptop >/dev/null
docker exec "$NAME" nginx -s reload >/dev/null 2>&1 || bad "nginx would not reload"
sleep 1
code="$(ask --cert "$WORK/laptop.crt" --key "$WORK/laptop.key")"
# 400 rather than the vhost's 403: a revoked certificate fails nginx's own
# verification against the revocation list, which happens before any location is
# chosen. What matters is that the same certificate that worked a moment ago does
# not now.
case "$code" in
	400 | 403) ok "the same certificate is refused after being revoked (HTTP $code)" ;;
	*) bad "a revoked certificate still gets in: got $code" ;;
esac

code="$(ask --cert "$WORK/phone.crt" --key "$WORK/phone.key")"
[ "$code" = 200 ] || bad "revoking one device locked out another: got $code"
ok "and the other device still gets in"

echo
log "all checks passed"
