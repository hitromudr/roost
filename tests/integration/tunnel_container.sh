#!/usr/bin/env bash
# Proves the way in for a machine that has no address of its own: a container
# stands in for the gate, this machine for the stand, and what is checked is that
# the terminal is reachable *from the gate* through the reverse forward — and only
# in the way the printed key line allows.
#
# The unit file's options are covered by the role and its tests. What cannot be
# covered without two machines is whether those options, that key restriction and
# that vhost actually carry a request from the far end to a terminal on this one.
# That is what this does.
#
#   tests/integration/tunnel_container.sh
#
# Needs docker and ssh.
set -euo pipefail

IMAGE="alpine:3.20"
NAME="roost-tunnel-test-$$"
WORK="$(mktemp -d)"
TERM_PORT=""
SSH_PORT=""
TUNNEL_PID=""

log() { printf '\033[1;34m[tunnel-test]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
bad() { printf '\033[1;31m  ✗\033[0m %s\n' "$*"; exit 1; }

command -v docker >/dev/null || { echo "docker not installed — skipping"; exit 0; }
command -v ssh >/dev/null || { echo "ssh not installed — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 not installed — skipping"; exit 0; }

cleanup() {
	[ -z "$TUNNEL_PID" ] || kill "$TUNNEL_PID" 2>/dev/null || true
	[ -z "${TERMINAL_PID:-}" ] || kill "$TERMINAL_PID" 2>/dev/null || true
	docker rm -f "$NAME" >/dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT

# --- something to be reached ---------------------------------------------
# The terminal's stand-in: one line, on this machine's loopback. What is under
# test is the path, not pockterm.
log "starting a stand-in for the terminal on this machine"
mkdir -p "$WORK/site"
printf 'terminal\n' > "$WORK/site/index.html"
# The port is chosen here rather than by asking the server which one it took:
# `http.server 0` announces it on stderr, buffered, and reading that back is a
# race the test would lose about one time in five.
TERM_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
(cd "$WORK/site" && exec python3 -m http.server "$TERM_PORT" --bind 127.0.0.1 >"$WORK/http.log" 2>&1) &
TERMINAL_PID=$!
for _ in $(seq 1 50); do
	if curl -s --max-time 1 "http://127.0.0.1:$TERM_PORT/" >/dev/null 2>&1; then break; fi
	sleep 0.2
done
curl -s --max-time 2 "http://127.0.0.1:$TERM_PORT/" >/dev/null ||
	bad "the stand-in terminal did not start: $(tail -2 "$WORK/http.log")"
ok "it answers on 127.0.0.1:$TERM_PORT"

# --- the gate ------------------------------------------------------------
log "starting a container to stand in for the gate"
ssh-keygen -q -t ed25519 -N '' -C 'roost tunnel test' -f "$WORK/id" </dev/null

# The key line roost prints for the gate: everything off, then one forward on.
# Copied here from `roost gate`'s own format on purpose — if that format changes
# in a way sshd does not accept, this test is where it shows.
REMOTE_PORT=18130
printf 'restrict,port-forwarding,permitlisten="127.0.0.1:%s" %s\n' \
	"$REMOTE_PORT" "$(cat "$WORK/id.pub")" > "$WORK/authorized_keys"

# An sshd this test configures itself, and that matters: the setting the forward
# depends on is one a hardened gate turns off, and a prepared image would either
# hide that or fail for its own reasons. This is the same file `roost gate`
# prints, so if that text stops being something sshd accepts, this is where it
# shows.
cat > "$WORK/roost-tunnel.conf" <<'SSHD'
Match User roost-tunnel
    AllowTcpForwarding yes
    PermitTTY no
    X11Forwarding no
    AllowAgentForwarding no
    PermitTunnel no
SSHD

# The container's setup as a file rather than as a quoted argument. The first
# version of this was a single-quoted script containing a sed expression in single
# quotes: the outer string ended early, sed ran on *this* machine against
# /etc/shadow, and the error came from the wrong host entirely.
cat > "$WORK/setup.sh" <<'SETUP'
set -e
apk add --no-cache openssh >/dev/null
ssh-keygen -A >/dev/null
adduser -D -H -s /sbin/nologin roost-tunnel
# Unlocked, and this is the trap: adduser leaves "!" in the password field, and
# sshd refuses a locked account before it ever looks at a key ("User roost-tunnel
# not allowed because account is locked"). A gate whose account was made that way
# rejects the tunnel while saying nothing about why on the stand's side.
passwd -u roost-tunnel >/dev/null 2>&1 || true
mkdir -p /home/roost-tunnel/.ssh
cp /keys/authorized_keys /home/roost-tunnel/.ssh/authorized_keys
chown -R roost-tunnel:roost-tunnel /home/roost-tunnel
chmod 700 /home/roost-tunnel/.ssh
chmod 600 /home/roost-tunnel/.ssh/authorized_keys
mkdir -p /etc/ssh/sshd_config.d
cp /keys/roost-tunnel.conf /etc/ssh/sshd_config.d/roost-tunnel.conf
# The gate this stands in for is a hardened one: forwarding off globally, and the
# file above is what turns it on for this account only. The Include comes after,
# because in sshd_config the first value of a keyword wins and a Match block is
# what overrides it.
printf 'AllowTcpForwarding no\nInclude /etc/ssh/sshd_config.d/*.conf\n' >> /etc/ssh/sshd_config
exec /usr/sbin/sshd -D -e
SETUP

docker run -d --name "$NAME" -p 127.0.0.1:0:22 \
	-v "$WORK/authorized_keys:/keys/authorized_keys:ro" \
	-v "$WORK/roost-tunnel.conf:/keys/roost-tunnel.conf:ro" \
	-v "$WORK/setup.sh:/keys/setup.sh:ro" \
	"$IMAGE" sh /keys/setup.sh >/dev/null 2>&1 ||
	{ echo "could not start $IMAGE — skipping"; exit 0; }
SSH_PORT="$(docker port "$NAME" 22/tcp | head -1 | sed 's/.*://')"
[ -n "$SSH_PORT" ] || bad "the container published no ssh port"

# Waited for, not asserted: with `restrict` on the key there is no command this
# could run to prove anything, and a loop whose failure prints "ok" anyway is
# worse than no check. The first real assertion is the forward itself.
#
# Waited for in the container's log, and not by connecting to the published port:
# docker-proxy accepts on that port from the moment the container starts, whether
# or not anything inside is listening yet. A probe that connects there succeeds
# against nothing, and the tunnel then fails with "Connection reset by peer" at
# the banner — which reads like a refused forward and is not one.
for _ in $(seq 1 120); do
	if docker logs "$NAME" 2>&1 | grep -q "Server listening"; then break; fi
	sleep 0.5
done
docker logs "$NAME" 2>&1 | grep -q "Server listening" ||
	bad "the gate's sshd never came up: $(docker logs "$NAME" 2>&1 | tail -3)"
ok "the gate is listening"

# --- the forward the unit holds ------------------------------------------
# The same options the unit uses, and for the same reasons: ExitOnForwardFailure
# so a refused forward is a failure rather than a connection that looks fine.
log "opening the reverse forward, with the unit's own options"
ssh -N -i "$WORK/id" -p "$SSH_PORT" \
	-o IdentitiesOnly=yes \
	-o ExitOnForwardFailure=yes \
	-o ServerAliveInterval=30 \
	-o ServerAliveCountMax=3 \
	-o StrictHostKeyChecking=no \
	-o UserKnownHostsFile="$WORK/known_hosts" \
	-R "127.0.0.1:$REMOTE_PORT:127.0.0.1:$TERM_PORT" \
	roost-tunnel@127.0.0.1 </dev/null >"$WORK/tunnel.log" 2>&1 &
TUNNEL_PID=$!
sleep 4
kill -0 "$TUNNEL_PID" 2>/dev/null ||
	bad "the forward was refused — ssh exited, which is ExitOnForwardFailure doing its job. ssh said: $(tail -3 "$WORK/tunnel.log"); the gate said: $(docker logs "$NAME" 2>&1 | tail -3)"
ok "it is holding"

log "asking the gate for the terminal, through the forward"
got="$(docker exec "$NAME" sh -c "wget -qO- http://127.0.0.1:$REMOTE_PORT/ 2>/dev/null" || true)"
[ "$got" = "terminal" ] || bad "the gate did not reach the terminal through the forward (got '$got')"
ok "the gate reaches the terminal on this machine"

# --- what the restriction is for -----------------------------------------
log "asking for a shell with the same key"
if ssh -p "$SSH_PORT" -i "$WORK/id" -o StrictHostKeyChecking=no \
	-o UserKnownHostsFile="$WORK/known_hosts" -o BatchMode=yes \
	roost-tunnel@127.0.0.1 "id" >/dev/null 2>&1; then
	bad "the tunnel key got a shell on the gate — restrict is not doing its job"
fi
ok "the key cannot get a shell"

log "asking for a second forward, on another port"
if ssh -N -i "$WORK/id" -p "$SSH_PORT" \
	-o ExitOnForwardFailure=yes -o StrictHostKeyChecking=no \
	-o UserKnownHostsFile="$WORK/known_hosts" -o BatchMode=yes \
	-o ConnectTimeout=5 \
	-R "127.0.0.1:19999:127.0.0.1:$TERM_PORT" \
	roost-tunnel@127.0.0.1 true 2>/dev/null; then
	bad "the key opened a forward it was not permitted — permitlisten is not doing its job"
fi
ok "the key cannot open any other forward"

echo
log "all checks passed"
