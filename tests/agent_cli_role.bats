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

    # The page a blocked region answers with, in the shape it actually
    # arrives: the title — the one line that says why — sits behind a few
    # hundred bytes of build stamp, domain attributes and preconnect hints.
    # Copied from the real refusal rather than shortened, because a fixture
    # with the answer in the first line tests a case that does not happen.
    cat > "$BATS_TEST_TMPDIR/blocked.html" <<'EOF'
<!DOCTYPE html><!-- Last Published: Thu Aug 06 2026 21:48:02 GMT+0000 (Coordinated Universal Time) --><html data-wf-domain="websitemain.claude.com" data-wf-page="68bd5cf2687bfe3893fd2b7f" data-wf-site="6889473510b50328dbb70ae6" data-wf-intellimize-customer-id="117902971" lang="en-US"><head><meta charset="utf-8"/><link href="https://cdn.prod.website-files.com" rel="preconnect" crossorigin="anonymous"/><title>App unavailable in region | Claude by Anthropic</title><meta content="Unfortunately, Claude isn't available here." name="description"/></head></html>
EOF

    # A real installer, reduced to the one thing the role checks for after it.
    cat > "$BATS_TEST_TMPDIR/install.sh" <<EOF
#!/usr/bin/env bash
printf 'agent\n' > "$BIN/claude"
chmod +x "$BIN/claude"
EOF

    # The role downloads to a fixed path. A file left there by an earlier run —
    # this suite's or a real one's — is exactly the trap under test below, so
    # each test starts without one.
    rm -f /tmp/roost-agent-install.sh 2>/dev/null || true

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

# run_role <installer file> — the role against a file:// URL for that file.
run_role() { run_role_url "file://$1"; }

# run_role_url <url> — what both go through.
run_role_url() {
    ANSIBLE_ROLES_PATH="$ROLES" ansible-playbook \
        -i "$BATS_TEST_TMPDIR/inventory" \
        "$BATS_TEST_TMPDIR/play.yml" \
        -e "agent_cli_user=$(id -un)" \
        -e "agent_cli_command=$BIN/claude" \
        -e "agent_cli_state_file=$BATS_TEST_TMPDIR/agent.env" \
        -e "agent_cli_installer_url=$1" \
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

@test "an answer with no title still says what came back" {
    # Not every refusal is a web page: a filtering proxy answers with JSON, an
    # error page can have no title at all. The title is the better half of the
    # message and not the only one, or this would report nothing whenever it is
    # the first case that shows up.
    printf '{"error":"forbidden by policy"}\n' > "$BATS_TEST_TMPDIR/denied.json"
    run run_role "$BATS_TEST_TMPDIR/denied.json"
    [ "$status" -ne 0 ]
    [[ "$output" == *"did not answer with a script"* ]]
    [[ "$output" == *"forbidden by policy"* ]]
}

@test "the download is forced, so yesterday's refusal is not today's report" {
    # The trap this cost an evening, and the one thing here the stand cannot
    # act out. get_url asks the server whether its copy is newer than the one
    # on disk; the first failed attempt had written a 470KB HTML page to the
    # fixed path, the answer was "no", and every later run read *that*. The
    # channel was fixed and proven by hand, and the role went on refusing with
    # a quotation from the day before — a message naming a response the server
    # no longer gives, which is worse than the refusal it replaced.
    #
    # Measured on the container this was found in: removing the file made the
    # very same command install the agent. Reproducing it needs a server that
    # answers a conditional request, and a background one hangs bats on the
    # descriptor it hands every test — so what is guarded here is the property
    # that makes the question moot.
    grep -A 8 'name: Fetch the official installer' \
        "$BATS_TEST_DIRNAME/../ansible/roles/agent_cli/tasks/main.yml" \
        | grep -q 'force: true'
}
