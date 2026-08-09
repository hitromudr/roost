#!/usr/bin/env bats
#
# What the agent installer does with an answer that is not an installer.
#
# The role fetched a URL and handed the file to bash. Every filter between a
# stand and its provider answers with an HTML page and the status of a success
# — a regional block, a captive portal, a proxy with an opinion — so the page
# was executed, and the whole report was a shell syntax error about `<` on line
# one. Measured 2026-08-09 in a container whose exit is not served by
# Anthropic: the file said `App unavailable in region | Claude by Anthropic`,
# and nothing read it.
#
# Same shape as env_sync_role.bats: no container, no root, skipped where
# ansible is absent. The installer is served over `file://`, which get_url
# takes and which needs no network — what is under test is what happens after
# the download, and a test that needed the real internet could not run where
# this defect was found.

setup() {
    command -v ansible-playbook >/dev/null || skip "ansible is not installed"

    ROLES="$BATS_TEST_DIRNAME/../ansible/roles"
    BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$BIN"

    # The page a blocked region answers with, cut to its first line.
    cat > "$BATS_TEST_TMPDIR/blocked.html" <<'EOF'
<!DOCTYPE html><html lang="en-US"><head><meta charset="utf-8"/>
<title>App unavailable in region | Claude by Anthropic</title></head></html>
EOF

    # A real installer, reduced to the one thing the role checks for after it.
    cat > "$BATS_TEST_TMPDIR/install.sh" <<EOF
#!/usr/bin/env bash
printf 'agent\n' > "$BIN/claude"
chmod +x "$BIN/claude"
EOF

    printf 'localhost ansible_connection=local\n' > "$BATS_TEST_TMPDIR/inventory"
    cat > "$BATS_TEST_TMPDIR/play.yml" <<'EOF'
---
- name: Install the agent
  hosts: localhost
  gather_facts: true
  roles:
    - agent_cli
EOF
}

# run_role <installer file> — the role against a URL that serves that file.
run_role() {
    ANSIBLE_ROLES_PATH="$ROLES" ansible-playbook \
        -i "$BATS_TEST_TMPDIR/inventory" \
        "$BATS_TEST_TMPDIR/play.yml" \
        -e "agent_cli_user=$(id -un)" \
        -e "agent_cli_command=$BIN/claude" \
        -e "agent_cli_state_file=$BATS_TEST_TMPDIR/agent.env" \
        -e "agent_cli_installer_url=file://$1" \
        2>&1
}

@test "a page instead of a script is refused, and named" {
    run run_role "$BATS_TEST_TMPDIR/blocked.html"
    [ "$status" -ne 0 ]
    # The point of the whole change: the report says what came back, not what
    # bash thought of it.
    [[ "$output" == *"did not answer with a script"* ]]
    [[ "$output" == *"App unavailable in region"* ]]
    # And nothing was run: the page must not reach a shell at all.
    [ ! -e "$BIN/claude" ]
}

@test "a real installer still runs" {
    # The guard has to let the ordinary case through, or it is a refusal to
    # install anything at all.
    run run_role "$BATS_TEST_TMPDIR/install.sh"
    [ "$status" -eq 0 ]
    [ -x "$BIN/claude" ]
}
