#!/usr/bin/env bats
#
# The tunnel script builds the autossh command line that keeps the stand
# reachable from the gate. Getting the flags wrong here means a tunnel that
# looks up but silently stops forwarding, so the command line is generated in
# one place and checked.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../ansible/roles/publish/files/tunnel-command"
    export TUNNEL_GATE_HOST=gate.example
    export TUNNEL_GATE_USER=tunnel
    export TUNNEL_GATE_PORT=22
    export TUNNEL_REMOTE_PORT=18130
    export TUNNEL_LOCAL_PORT=8130
    export TUNNEL_KEY=/etc/roost/tunnel_key
}

@test "forwards the local terminal port to the gate" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"-R 18130:127.0.0.1:8130"* ]]
    [[ "$output" == *"tunnel@gate.example"* ]]
}

@test "uses the dedicated key and no other" {
    run "$SCRIPT"
    [[ "$output" == *"-i /etc/roost/tunnel_key"* ]]
    [[ "$output" == *"IdentitiesOnly=yes"* ]]
}

@test "keeps the tunnel honest: dead connections are detected" {
    run "$SCRIPT"
    # Without these a dropped link leaves a socket that accepts and discards
    # traffic; the gate would return 502 while the tunnel "runs".
    [[ "$output" == *"ServerAliveInterval"* ]]
    [[ "$output" == *"ServerAliveCountMax"* ]]
    [[ "$output" == *"ExitOnForwardFailure=yes"* ]]
}

@test "no shell, no tty: the tunnel is not a login" {
    run "$SCRIPT"
    [[ "$output" == *" -N"* ]]
    [[ "$output" == *" -T"* ]]
}

@test "a non-default gate port is honoured" {
    TUNNEL_GATE_PORT=2222 run "$SCRIPT"
    [[ "$output" == *"-p 2222"* ]]
}

@test "missing configuration is refused, not defaulted" {
    unset TUNNEL_GATE_HOST
    run "$SCRIPT"
    [ "$status" -ne 0 ]
}
