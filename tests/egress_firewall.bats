#!/usr/bin/env bats
#
# The firewall script can print the rules it would apply instead of applying
# them. That is what makes the policy testable without root, and it is also
# what `roost doctor` compares a live machine against.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../ansible/roles/egress_sandbox/files/egress-firewall"
    export EGRESS_GROUP=agent-sandbox
    export EGRESS_GID=4242
    export EGRESS_PROFILE=pinned
    export EGRESS_ALLOW=""
}


# no_iptables_path builds a PATH with everything the script needs except the one
# thing under test. bash included: the script's shebang is `env bash`, and
# without it the run fails with 127 before reaching any check — which is a test
# measuring its own PATH rather than the script.
no_iptables_path() {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    local t src
    for t in bash cat grep sed awk; do
        src="$(command -v "$t" 2>/dev/null)" || continue
        ln -sf "$src" "$BATS_TEST_TMPDIR/bin/$t"
    done
}

rules() {
    run "$SCRIPT" rules
    [ "$status" -eq 0 ]
}

@test "pinned: loopback allowed, everything else rejected" {
    rules
    [[ "$output" == *"-o lo"*"--gid-owner 4242"*"ACCEPT"* ]]
    [[ "$output" == *"-d 127.0.0.0/8"*"--gid-owner 4242"*"ACCEPT"* ]]
    [[ "$output" == *"--gid-owner 4242"*"REJECT"* ]]
}

@test "pinned: the reject rule comes last" {
    rules
    local reject_line accept_line
    reject_line=$(echo "$output" | grep -n "REJECT" | head -1 | cut -d: -f1)
    accept_line=$(echo "$output" | grep -n "127.0.0.0/8" | head -1 | cut -d: -f1)
    # A reject placed before the accepts would cut off the local proxy too.
    [ "$reject_line" -gt "$accept_line" ]
}

@test "ipv6 is covered, not just ipv4" {
    rules
    [[ "$output" == *"ip6tables"* ]]
    [[ "$output" == *"::1/128"* ]]
    # An ipv4-only policy leaks: a dual-stack host would happily use v6.
    [[ "$output" == *"ip6tables"*"REJECT"* ]]
}

@test "proxied: listed destinations are allowed on top of loopback" {
    EGRESS_PROFILE=proxied EGRESS_ALLOW="10.0.0.0/8 192.0.2.7" rules
    [[ "$output" == *"-d 10.0.0.0/8"*"ACCEPT"* ]]
    [[ "$output" == *"-d 192.0.2.7"*"ACCEPT"* ]]
    [[ "$output" == *"REJECT"* ]]
}

@test "direct: no rules at all" {
    EGRESS_PROFILE=direct rules
    [ -z "$(echo "$output" | grep -v '^#' | grep -v '^[[:space:]]*$')" ]
}

@test "unknown profile is refused" {
    EGRESS_PROFILE=whatever run "$SCRIPT" rules
    [ "$status" -ne 0 ]
    [[ "$output" == *"whatever"* ]]
}

@test "missing gid is refused rather than guessed" {
    unset EGRESS_GID
    run "$SCRIPT" rules
    [ "$status" -ne 0 ]
}

@test "every rule carries the comment tag, so clear removes exactly ours" {
    rules
    while read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" == *"--comment"*"$EGRESS_GROUP"* ]]
    done <<< "$output"
}

# What happens on a host that has no iptables at all.
#
# Measured 2026-08-10 installing a stand into a clean Debian 13 container: the
# unit exited 127 with `egress-firewall: line 78: iptables: command not found`,
# and `roost install` reported "Unable to start service egress-firewall" — a
# sentence about systemd, on a machine whose sandbox was simply not installable
# yet. Such a host has nftables instead, and what bridges the two is a package.
@test "apply names the missing tool instead of failing on line 78" {
    # A PATH with the shell's own tools and no iptables. Not an empty PATH: the
    # script is bash and needs its own utilities to get as far as the check.
    no_iptables_path
    run env PATH="$BATS_TEST_TMPDIR/bin" "$SCRIPT" apply
    [ "$status" -ne 0 ]
    [[ "$output" == *"iptables"* ]]
    [[ "$output" == *"not installed"* ]]
}

@test "direct needs no iptables, and must not ask for one" {
    # The profile that installs nothing has no use for the tool, and a host
    # that chose it must not be refused a sandbox over a package it will never
    # call.
    no_iptables_path
    run env PATH="$BATS_TEST_TMPDIR/bin" EGRESS_PROFILE=direct "$SCRIPT" apply
    [ "$status" -eq 0 ]
}
