#!/usr/bin/env bats
#
# The credentials file, on a machine that has never had one.
#
# A stand installed from a config file supplies the proxy URL, so the task that
# writes the file is the only one that creates it — the seeding task is skipped
# in that case. Standing before it, the task that fixes the file's ownership
# failed with "file (/etc/roost/agent-proxy.env) is absent, cannot continue",
# and the install stopped with the sandbox half configured. The old order worked
# only on a machine where somebody had already created that file by hand, which
# was every machine roost had been installed on until then (found on a fresh
# VPS, 2026-08-05).
#
# This checks the order and nothing else. Running those two tasks for real needs
# root, a group and a firewall: that is what `make test-integration` does in a
# container, and what a run on a live stand proves.

setup() {
    ROLE="$BATS_TEST_DIRNAME/../ansible/roles/egress_sandbox/tasks/main.yml"
}

@test "the credentials file is written before its ownership is set" {
    local write keep
    write="$(grep -n 'name: Write the credentials file' "$ROLE" | cut -d: -f1)"
    keep="$(grep -n 'name: Keep the credentials file readable' "$ROLE" | cut -d: -f1)"
    [ -n "$write" ]
    [ -n "$keep" ]
    [ "$write" -lt "$keep" ]
}

# The other half of the same story: with no URL supplied the file is seeded
# instead, and that task must not overwrite what an operator typed into it.
@test "the seeded file is never overwritten" {
    grep -A12 'name: Seed the credentials file' "$ROLE" | grep -q 'force: false'
}

# An agent's own proxy file (egress_sandbox_agent_env) follows the same rule.
@test "an agent's own proxy file is seeded, never overwritten" {
    grep -A12 "name: Seed each agent's own proxy file" "$ROLE" | grep -q 'force: false'
}

@test "an agent's file carries the lines named for it" {
    command -v python3 >/dev/null && python3 -c 'import jinja2' 2>/dev/null || skip "no jinja2"
    run python3 - "$BATS_TEST_DIRNAME/../ansible/roles/egress_sandbox/templates/agent.env.j2" <<'PY'
import sys, jinja2
env = jinja2.Environment(trim_blocks=True)
t = env.from_string(open(sys.argv[1]).read())
print(t.render(ansible_managed="x", egress_sandbox_agent_suffix="-safe",
               item={"key": "gemini-sub", "value": "/bin/gemini"},
               egress_sandbox_agent_env={"gemini-sub": {"AGENT_ENV_FILE": "/etc/p.env", "B": "2"}}))
print("---")
print(t.render(ansible_managed="x", egress_sandbox_agent_suffix="-safe",
               item={"key": "codex", "value": "/bin/codex"}, egress_sandbox_agent_env={}))
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *$'AGENT_COMMAND=/bin/gemini\nAGENT_ENV_FILE=/etc/p.env\nB=2'* ]]
    [[ "${output#*---}" != *"AGENT_ENV_FILE"* ]]
}
