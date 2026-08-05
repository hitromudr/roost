#!/usr/bin/env bats
#
# The roost wrapper is what a user actually types. These tests cover the
# parts that do not need a machine: reading and writing the config, refusing
# a configuration that cannot work, and what doctor concludes from a given
# state. Applying roles is covered by the role and container tests.

setup() {
    ROOST="$BATS_TEST_DIRNAME/../roost"
    export ROOST_CONF="$BATS_TEST_TMPDIR/roost.conf"
    STUB_DIR="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$STUB_DIR"
    for tool in ansible-playbook systemctl tmux; do
        printf '#!/usr/bin/env bash\necho "%s $*" >> "$STUB_LOG"\nexit ${STUB_RC:-0}\n' "$tool" \
            > "$STUB_DIR/$tool"
        chmod +x "$STUB_DIR/$tool"
    done
    PATH="$STUB_DIR:$PATH"
    export PATH STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    : > "$STUB_LOG"
}

write_conf() {
    cat > "$ROOST_CONF" <<EOF
egress_profile=${1-pinned}
agent_command=/usr/local/bin/claude
EOF
}

@test "help is printed without a config and without failing" {
    run "$ROOST" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"install"* ]]
    [[ "$output" == *"doctor"* ]]
}

@test "an unknown command fails with a usage hint" {
    run "$ROOST" frobnicate
    [ "$status" -ne 0 ]
    [[ "$output" == *"frobnicate"* ]]
}

@test "install without a config asks to run the wizard" {
    run "$ROOST" install
    [ "$status" -ne 0 ]
    [[ "$output" == *"setup"* || "$output" == *"roost.conf"* ]]
}

@test "install passes the config through to ansible as variables" {
    write_conf
    run "$ROOST" install
    [ "$status" -eq 0 ]
    grep -q "ansible-playbook" "$STUB_LOG"
    grep -q "egress_sandbox_profile=pinned" "$STUB_LOG"
}

@test "an unknown egress profile is refused" {
    write_conf sieve
    run "$ROOST" install
    [ "$status" -ne 0 ]
    [[ "$output" == *"sieve"* ]]
    ! grep -q "ansible-playbook" "$STUB_LOG"
}

@test "uninstall promises nothing about what roost did not install" {
    # The sandbox is roost's; the web terminal, the tunnel and the shell on
    # this machine belong to whoever put them there. They may be named in the
    # "keeps" half — that is the point — but never in what goes.
    write_conf
    run "$ROOST" uninstall --dry-run
    local removed
    removed="$(sed -n '1,/It keeps:/p' <<< "$output")"
    [[ "$removed" != *"web terminal"* ]]
    [[ "$removed" != *"tunnel"* ]]
    [[ "$removed" == *"egress rules"* ]]
}

@test "doctor reports on a machine where nothing is installed" {
    write_conf
    STUB_RC=1 run "$ROOST" doctor
    # Nothing installed is a finding, not a crash.
    [ "$status" -ne 0 ]
    [[ "$output" == *"egress"* ]]
}

@test "doctor names the fix, not just the symptom" {
    write_conf
    STUB_RC=1 run "$ROOST" doctor
    [[ "$output" == *"roost install"* ]]
}

@test "uninstall says what goes and what stays before doing anything" {
    write_conf
    run "$ROOST" uninstall --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"egress rules"* ]]
    [[ "$output" == *"keeps"* ]]
    [[ "$output" == *"projects"* ]]
    # A dry run must not touch the machine.
    ! grep -q "ansible-playbook" "$STUB_LOG"
}

@test "uninstall without --purge keeps the group" {
    write_conf
    run "$ROOST" uninstall --dry-run
    [[ "$output" == *"sandbox group"* ]]
    [[ "$output" == *"--purge"* ]]
}

@test "uninstall --yes proceeds without asking" {
    write_conf
    run "$ROOST" uninstall --yes
    [ "$status" -eq 0 ]
    grep -q "teardown.yml" "$STUB_LOG"
}

@test "uninstall --purge passes the flag through" {
    write_conf
    run "$ROOST" uninstall --yes --purge
    grep -q "roost_purge=true" "$STUB_LOG"
}

@test "an unknown uninstall option is refused" {
    write_conf
    run "$ROOST" uninstall --wipe-everything
    [ "$status" -ne 0 ]
}

# --- project list -------------------------------------------------------

write_projects() {
    printf '%s\n' \
        '# name  repository  [branch]' \
        'notes   https://git.example/you/notes.git' \
        'webapp  https://github.com/example/webapp.git  develop' \
        > "$BATS_TEST_TMPDIR/projects.conf"
    export ROOST_PROJECTS="$BATS_TEST_TMPDIR/projects.conf"
}

@test "the project list is parsed into name, repo and branch" {
    write_conf
    write_projects
    run "$ROOST" projects --list
    [ "$status" -eq 0 ]
    [[ "$output" == *'"name":"notes"'* ]]
    [[ "$output" == *'"repo":"https://git.example/you/notes.git"'* ]]
    [[ "$output" == *'"version":"develop"'* ]]
}

@test "a project without a branch tracks the repository head" {
    write_conf
    write_projects
    run "$ROOST" projects --list
    [[ "$output" == *'"name":"notes","repo":"https://git.example/you/notes.git","version":"HEAD"'* ]]
}

@test "comments and blank lines are ignored" {
    write_conf
    write_projects
    run "$ROOST" projects --list
    [ "$(grep -o '"name"' <<< "$output" | wc -l)" -eq 2 ]
}

@test "a malformed line is refused, naming the line" {
    write_conf
    printf 'brokenline\n' > "$BATS_TEST_TMPDIR/projects.conf"
    export ROOST_PROJECTS="$BATS_TEST_TMPDIR/projects.conf"
    run "$ROOST" projects --list
    [ "$status" -ne 0 ]
    [[ "$output" == *"brokenline"* ]]
}

@test "no project list is not an error, just nothing to do" {
    write_conf
    export ROOST_PROJECTS="$BATS_TEST_TMPDIR/absent.conf"
    run "$ROOST" projects
    [ "$status" -eq 0 ]
    [[ "$output" == *"no projects"* ]]
    ! grep -q "projects.yml" "$STUB_LOG"
}

@test "projects works on a machine that has no stand config" {
    # The same list is applied on a machine that runs no agents and has no
    # roost.conf to read.
    write_projects
    run "$ROOST" projects
    [ "$status" -eq 0 ]
    grep -q "projects.yml" "$STUB_LOG"
    grep -q "projects_dir=$HOME/work" "$STUB_LOG"
}

@test "projects runs the playbook with the parsed list" {
    write_conf
    write_projects
    run "$ROOST" projects
    [ "$status" -eq 0 ]
    grep -q "projects.yml" "$STUB_LOG"
    grep -q "notes" "$STUB_LOG"
}

@test "the list reaches ansible as json, not as a string" {
    # Passed as key=value it arrives as a string, and `| length` then counts
    # characters — the summary claimed 91 projects for one.
    write_conf
    write_projects
    run "$ROOST" projects
    grep -q '{"projects_list":' "$STUB_LOG"
}

@test "the user list reaches ansible as json, not as a string" {
    # As key=value it arrives as a string and `| first` returns "[", which
    # ansible then tries to look up as a user account.
    write_conf
    run "$ROOST" install
    grep -q '{"egress_sandbox_users":' "$STUB_LOG"
}

@test "doctor calls out a sandbox with no way out" {
    write_conf
    export ROOST_PROXY_ENV="$BATS_TEST_TMPDIR/proxy.env"
    printf '# PROXY_URL=http://user:pass@host:port\n' > "$ROOST_PROXY_ENV"
    STUB_RC=1 run "$ROOST" doctor
    # A commented-out example is not a proxy.
    [[ "$output" == *"no network at all"* ]]
    [[ "$output" == *"PROXY_URL="* ]]
}

@test "doctor is satisfied when the proxy is configured" {
    write_conf
    export ROOST_PROXY_ENV="$BATS_TEST_TMPDIR/proxy.env"
    printf 'PROXY_URL=http://user:pass@127.0.0.1:8129\n' > "$ROOST_PROXY_ENV"
    STUB_RC=1 run "$ROOST" doctor
    [[ "$output" == *"has a proxy"* ]]
}

@test "doctor calls out a credentials file the launcher cannot read" {
    # Readable by anyone means the proxy password is readable by anyone; the
    # other half of this — owned by root — is what killed sessions on the Pi.
    write_conf
    export ROOST_PROXY_ENV="$BATS_TEST_TMPDIR/proxy.env"
    printf 'PROXY_URL=http://user:pass@127.0.0.1:8129\n' > "$ROOST_PROXY_ENV"
    chmod 644 "$ROOST_PROXY_ENV"
    STUB_RC=1 run "$ROOST" doctor
    [[ "$output" == *"permissions 644"* ]]
    [[ "$output" == *"chmod 640"* ]]
}

@test "the direct profile is not nagged about a proxy" {
    write_conf direct
    export ROOST_PROXY_ENV="$BATS_TEST_TMPDIR/absent.env"
    STUB_RC=1 run "$ROOST" doctor
    # Unrestricted egress was the choice; there is nothing to proxy through.
    [[ "$output" != *"no network at all"* ]]
}

# --- extra agents -------------------------------------------------------

@test "install passes the extra agents to ansible" {
    write_conf
    printf 'agents=codex:/home/you/.local/bin/codex\n' >> "$ROOST_CONF"
    run "$ROOST" install
    [ "$status" -eq 0 ]
    grep -q '"egress_sandbox_agents": {"codex":"/home/you/.local/bin/codex"}' "$STUB_LOG"
}

@test "two extra agents are both passed" {
    write_conf
    printf 'agents=codex:/opt/codex,qwen:/opt/qwen\n' >> "$ROOST_CONF"
    run "$ROOST" install
    [ "$status" -eq 0 ]
    grep -q '"codex":"/opt/codex","qwen":"/opt/qwen"' "$STUB_LOG"
}

@test "an agent without a command is refused before anything is applied" {
    write_conf
    printf 'agents=codex\n' >> "$ROOST_CONF"
    run "$ROOST" install
    [ "$status" -ne 0 ]
    [[ "$output" == *"no command"* ]]
    # A name that would become a file name and a launcher name must not reach
    # ansible half-formed.
    ! grep -q "ansible-playbook" "$STUB_LOG"
}

@test "an agent name that would not make a usable launcher is refused" {
    write_conf
    printf 'agents=../etc/codex:/opt/codex\n' >> "$ROOST_CONF"
    run "$ROOST" install
    [ "$status" -ne 0 ]
    [[ "$output" == *"usable agent name"* ]]
}

@test "doctor names an extra agent whose launcher is not installed" {
    write_conf
    printf 'agents=frobnicate:/usr/bin/true\n' >> "$ROOST_CONF"
    run "$ROOST" doctor
    [ "$status" -ne 0 ]
    [[ "$output" == *"frobnicate"* ]]
    [[ "$output" == *"roost install"* ]]
}

# --- the one command, and the pieces it is made of -----------------------
# These cover what the wrapper decides on its own: which command starts a
# session, what is asked before something is published, and what is refused
# for want of a step before it. Applying the roles is the roles' own tests.

@test "help mentions the one command" {
    run "$ROOST" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"roost up"* ]]
}

@test "the agent roost installed is what the launcher is pointed at" {
    cat > "$ROOST_CONF" <<CONF
egress_profile=direct
agent_command=
CONF
    export ROOST_AGENT_STATE="$BATS_TEST_TMPDIR/agent.env"
    printf 'AGENT_INSTALLED_COMMAND=/opt/agents/claude\n' > "$ROOST_AGENT_STATE"
    run "$ROOST" install
    [ "$status" -eq 0 ]
    grep -q "egress_sandbox_agent_command=/opt/agents/claude" "$STUB_LOG"
}

@test "a command named in the config outranks what was installed" {
    write_conf
    export ROOST_AGENT_STATE="$BATS_TEST_TMPDIR/agent.env"
    printf 'AGENT_INSTALLED_COMMAND=/opt/agents/claude\n' > "$ROOST_AGENT_STATE"
    run "$ROOST" install
    [ "$status" -eq 0 ]
    grep -q "egress_sandbox_agent_command=/usr/local/bin/claude" "$STUB_LOG"
}

@test "the path an installer chose is written back into the config" {
    cat > "$ROOST_CONF" <<CONF
egress_profile=direct
agent_command=
CONF
    export ROOST_AGENT_STATE="$BATS_TEST_TMPDIR/agent.env"
    printf 'AGENT_INSTALLED_COMMAND=/home/x/.local/bin/claude\n' > "$ROOST_AGENT_STATE"
    run "$ROOST" agent
    [ "$status" -eq 0 ]
    grep -q "^agent_command=/home/x/.local/bin/claude$" "$ROOST_CONF"
}

@test "the agent step is asked for by tag, not by running everything" {
    write_conf
    run "$ROOST" agent
    [ "$status" -eq 0 ]
    grep -q -- "--tags agent" "$STUB_LOG"
}

@test "install does not run the terminal or the way in" {
    write_conf
    run "$ROOST" install
    [ "$status" -eq 0 ]
    grep -q -- "--tags egress,sessions,env" "$STUB_LOG"
    ! grep -q -- "--tags terminal" "$STUB_LOG"
}

@test "a stand that wants no terminal is not given one" {
    write_conf
    printf 'terminal=false\n' >> "$ROOST_CONF"
    run "$ROOST" terminal
    [ "$status" -eq 0 ]
    ! grep -q "ansible-playbook" "$STUB_LOG"
}

@test "publishing is not done without being asked" {
    write_conf
    run "$ROOST" expose < /dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"full shell"* ]]
    ! grep -q "ansible-playbook" "$STUB_LOG"
}

@test "publishing with --yes says which port and which upstream" {
    write_conf
    printf 'listen=127.0.0.1:8130\ntls_port=9443\n' >> "$ROOST_CONF"
    run "$ROOST" expose --yes
    [ "$status" -eq 0 ]
    grep -q "expose_tls_port=9443" "$STUB_LOG"
    grep -q "expose_upstream=127.0.0.1:8130" "$STUB_LOG"
}

@test "a host given on the command line wins over the config" {
    write_conf
    printf 'public_host=from.conf\n' >> "$ROOST_CONF"
    run "$ROOST" expose --yes --host from.flag
    [ "$status" -eq 0 ]
    grep -q "expose_host=from.flag" "$STUB_LOG"
}

@test "printing what to add asks nobody and changes nothing" {
    write_conf
    run "$ROOST" expose --print < /dev/null
    [ "$status" -eq 0 ]
    grep -q "expose_front=print" "$STUB_LOG"
}

@test "an unknown expose option is refused" {
    write_conf
    run "$ROOST" expose --sideways
    [ "$status" -ne 0 ]
    [[ "$output" == *"--sideways"* ]]
}

@test "a QR code before anything is published says what is missing" {
    write_conf
    export ROOST_EXPOSE_STATE="$BATS_TEST_TMPDIR/expose.env"
    run "$ROOST" qr
    [ "$status" -ne 0 ]
    [[ "$output" == *"roost expose"* ]]
}

@test "a QR code without a terminal names the step that installs one" {
    write_conf
    export ROOST_EXPOSE_STATE="$BATS_TEST_TMPDIR/expose.env"
    # Named rather than absent from PATH: this suite also runs on a stand,
    # where pockterm is installed and "not installed" cannot be arranged by
    # leaving it out.
    export ROOST_POCKTERM_BIN=pockterm-that-is-not-here
    printf 'EXPOSE_URL=https://example:8443\n' > "$ROOST_EXPOSE_STATE"
    run "$ROOST" qr
    [ "$status" -ne 0 ]
    [[ "$output" == *"roost terminal"* ]]
}

@test "doctor says which binary a session would start" {
    cat > "$ROOST_CONF" <<CONF
egress_profile=direct
agent_command=$BATS_TEST_TMPDIR/claude
CONF
    printf '#!/bin/sh\n' > "$BATS_TEST_TMPDIR/claude"
    chmod +x "$BATS_TEST_TMPDIR/claude"
    run "$ROOST" doctor
    [[ "$output" == *"the agent is $BATS_TEST_TMPDIR/claude"* ]]
}

@test "doctor calls out an agent that is not there" {
    cat > "$ROOST_CONF" <<CONF
egress_profile=direct
agent_command=$BATS_TEST_TMPDIR/absent
CONF
    run "$ROOST" doctor
    [ "$status" -ne 0 ]
    [[ "$output" == *"not an executable file"* ]]
    [[ "$output" == *"roost agent"* ]]
}

@test "doctor calls out a terminal whose buttons bypass the sandbox" {
    cat > "$ROOST_CONF" <<CONF
egress_profile=direct
agent_command=/usr/bin/true
CONF
    export ROOST_TERMINAL_STATE="$BATS_TEST_TMPDIR/terminal.env"
    export ROOST_TERMINAL_ENV="$BATS_TEST_TMPDIR/pockterm.env"
    printf 'TERMINAL_LISTEN=127.0.0.1:8130\n' > "$ROOST_TERMINAL_STATE"
    printf 'CLAUDE=claude\n' > "$ROOST_TERMINAL_ENV"
    run "$ROOST" doctor
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsandboxed"* ]]
}

@test "doctor is satisfied when the buttons go through the launcher" {
    cat > "$ROOST_CONF" <<CONF
egress_profile=direct
agent_command=/usr/bin/true
CONF
    export ROOST_TERMINAL_STATE="$BATS_TEST_TMPDIR/terminal.env"
    export ROOST_TERMINAL_ENV="$BATS_TEST_TMPDIR/pockterm.env"
    printf 'TERMINAL_LISTEN=127.0.0.1:8130\n' > "$ROOST_TERMINAL_STATE"
    printf 'CLAUDE=/usr/local/bin/agent-run\n' > "$ROOST_TERMINAL_ENV"
    run "$ROOST" doctor
    [[ "$output" == *"go through the sandbox"* ]]
}

# --- which address the agent goes out from -------------------------------
# The claim the pinned profile exists for, and the one that costs an account
# rather than an afternoon when it is wrong. Until 2026-08-05 nothing checked
# it: a stand was pointed at a local proxy that answered, and the proxy came
# out of the machine's own address.
#
# The stubs stand in for the two things the check uses: `sg`, which runs its
# command in the group, and `curl`, which answers differently depending on
# whether it was handed a proxy — that is how the two addresses in the check
# are told apart.
exit_stubs() {
    export ROOST_PROXY_ENV="$BATS_TEST_TMPDIR/proxy.env"
    export ROOST_AGENT_RUN_ENV="$BATS_TEST_TMPDIR/agent-run.env"
    printf 'PROXY_URL=http://user:pass@127.0.0.1:8129\n' > "$ROOST_PROXY_ENV"
    printf 'AGENT_GROUP=agent-sandbox\n' > "$ROOST_AGENT_RUN_ENV"
    cat > "$STUB_DIR/sg" <<'STUB'
#!/usr/bin/env bash
# sg <group> -c <command>: run it, as the real one does.
shift 2
bash -c "$1"
STUB
    cat > "$STUB_DIR/curl" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do
    case "\$arg" in
        *api.anthropic.com*) printf 401; exit 0 ;;
        *8443*) printf 200; exit 0 ;;
    esac
done
# The address probe: through the proxy, or from the machine itself.
if [ -n "\${HTTPS_PROXY:-}" ]; then printf '%s\n' "${1:-198.51.100.7}"
else printf '%s\n' "${2:-203.0.113.5}"; fi
STUB
    chmod +x "$STUB_DIR/sg" "$STUB_DIR/curl"
}

@test "doctor says which address the agent goes out from" {
    write_conf
    exit_stubs 198.51.100.7 203.0.113.5
    run "$ROOST" doctor
    [[ "$output" == *"goes out from 198.51.100.7"* ]]
}

@test "an exit address that is not the expected one is a failure, not a note" {
    write_conf
    printf 'expected_exit=192.0.2.1\n' >> "$ROOST_CONF"
    exit_stubs 198.51.100.7 203.0.113.5
    run "$ROOST" doctor
    [ "$status" -ne 0 ]
    [[ "$output" == *"198.51.100.7"* ]]
    [[ "$output" == *"192.0.2.1"* ]]
    [[ "$output" == *"suspended"* ]]
}

@test "the expected exit address is confirmed when it matches" {
    write_conf
    printf 'expected_exit=198.51.100.7\n' >> "$ROOST_CONF"
    exit_stubs 198.51.100.7 203.0.113.5
    run "$ROOST" doctor
    [[ "$output" == *"as expected"* ]]
}

# The case that actually happened: a proxy that answers, and comes out of the
# machine it runs on. Nothing is broken and nothing is gained — worth saying,
# because "the sandbox has a proxy" reads as approval.
@test "a proxy that comes out of this machine's own address is called out" {
    write_conf
    exit_stubs 203.0.113.5 203.0.113.5
    run "$ROOST" doctor
    [[ "$output" == *"this machine's own address"* ]]
    [[ "$output" == *"changes nothing"* ]]
}

# --- the other lock ------------------------------------------------------

@test "enrolment is refused when the lock is a token" {
    write_conf
    export ROOST_EXPOSE_STATE="$BATS_TEST_TMPDIR/expose.env"
    printf 'EXPOSE_URL=https://x:8443\n' > "$ROOST_EXPOSE_STATE"
    run "$ROOST" enroll phone
    [ "$status" -ne 0 ]
    [[ "$output" == *"client_auth"* ]]
    [[ "$output" == *"mtls"* ]]
}

@test "enrolment without a device name asks for one" {
    write_conf
    printf 'client_auth=mtls\n' >> "$ROOST_CONF"
    run "$ROOST" enroll
    [ "$status" -ne 0 ]
    [[ "$output" == *"which device"* ]]
}

@test "enrolment before anything is published names the step that publishes" {
    write_conf
    printf 'client_auth=mtls\n' >> "$ROOST_CONF"
    export ROOST_EXPOSE_STATE="$BATS_TEST_TMPDIR/absent.env"
    run "$ROOST" enroll phone
    [ "$status" -ne 0 ]
    [[ "$output" == *"roost expose"* ]]
}

@test "the lock reaches ansible, so the vhost knows which one to write" {
    write_conf
    printf 'client_auth=mtls\n' >> "$ROOST_CONF"
    run "$ROOST" expose --yes
    [ "$status" -eq 0 ]
    grep -q "expose_client_auth=mtls" "$STUB_LOG"
}

# The check that matters here is inverted: with a certificate lock, a request
# that carries none and is *let through* is the failure.
@test "doctor calls out a certificate lock that lets an anonymous request in" {
    cat > "$ROOST_CONF" <<CONF
egress_profile=direct
agent_command=/usr/bin/true
CONF
    export ROOST_EXPOSE_STATE="$BATS_TEST_TMPDIR/expose.env"
    printf 'EXPOSE_URL=https://x:8443\nEXPOSE_CLIENT_AUTH=mtls\n' > "$ROOST_EXPOSE_STATE"
    # curl says 200: the lock is not on.
    printf '#!/usr/bin/env bash\nprintf 200\n' > "$STUB_DIR/curl"
    chmod +x "$STUB_DIR/curl"
    run "$ROOST" doctor
    [ "$status" -ne 0 ]
    [[ "$output" == *"the lock is not on"* ]]
}

@test "doctor is satisfied when the certificate lock refuses an anonymous request" {
    cat > "$ROOST_CONF" <<CONF
egress_profile=direct
agent_command=/usr/bin/true
CONF
    export ROOST_EXPOSE_STATE="$BATS_TEST_TMPDIR/expose.env"
    printf 'EXPOSE_URL=https://x:8443\nEXPOSE_CLIENT_AUTH=mtls\n' > "$ROOST_EXPOSE_STATE"
    printf '#!/usr/bin/env bash\nprintf 403\n' > "$STUB_DIR/curl"
    chmod +x "$STUB_DIR/curl"
    run "$ROOST" doctor
    [[ "$output" == *"refuses a request with no client certificate"* ]]
}

@test "doctor warns about a bundle still on offer" {
    cat > "$ROOST_CONF" <<CONF
egress_profile=direct
agent_command=/usr/bin/true
CONF
    export ROOST_EXPOSE_STATE="$BATS_TEST_TMPDIR/expose.env"
    mkdir -p "$BATS_TEST_TMPDIR/enroll"
    touch "$BATS_TEST_TMPDIR/enroll/deadbeef.p12"
    printf 'EXPOSE_URL=https://x:8443\nEXPOSE_CLIENT_AUTH=mtls\nEXPOSE_ENROLL_DIR=%s\n' \
        "$BATS_TEST_TMPDIR/enroll" > "$ROOST_EXPOSE_STATE"
    printf '#!/usr/bin/env bash\nprintf 403\n' > "$STUB_DIR/curl"
    chmod +x "$STUB_DIR/curl"
    run "$ROOST" doctor
    [[ "$output" == *"still published"* ]]
}

# --- a way in for a machine that has no address --------------------------
# The stand's half is a unit and a key (the tunnel role). The gate's half is
# printed, because it is somebody else's machine — so what these cover is what
# gets printed, and that nothing is applied unless it was asked for.

gate_state() {
    export ROOST_TUNNEL_STATE="$BATS_TEST_TMPDIR/tunnel.env"
    printf '%s\n' \
        "TUNNEL_GATE=roost-tunnel@gate.example" \
        "TUNNEL_REMOTE_PORT=18130" \
        "TUNNEL_KEY=$BATS_TEST_TMPDIR/id" \
        "TUNNEL_PUBKEY=$BATS_TEST_TMPDIR/id.pub" \
        "TUNNEL_UNIT=/etc/systemd/system/roost-tunnel.service" \
        > "$ROOST_TUNNEL_STATE"
    printf 'ssh-ed25519 AAAAKEY roost tunnel\n' > "$BATS_TEST_TMPDIR/id.pub"
}

@test "the tunnel is refused when no gate is named" {
    write_conf
    run "$ROOST" tunnel
    [ "$status" -ne 0 ]
    [[ "$output" == *"gate=user@host"* ]]
}

@test "the tunnel forwards the terminal's own port to the gate" {
    write_conf
    printf 'gate=roost-tunnel@gate.example\ngate_port=19999\nlisten=127.0.0.1:8130\n' >> "$ROOST_CONF"
    run "$ROOST" tunnel
    [ "$status" -eq 0 ]
    grep -q -- "--tags tunnel" "$STUB_LOG"
    grep -q "tunnel_gate=roost-tunnel@gate.example" "$STUB_LOG"
    grep -q "tunnel_remote_port=19999" "$STUB_LOG"
    grep -q "tunnel_local=127.0.0.1:8130" "$STUB_LOG"
}

@test "the gate is told to permit exactly one forward" {
    write_conf
    printf 'gate=roost-tunnel@gate.example\npublic_host=terminal.example\n' >> "$ROOST_CONF"
    gate_state
    run "$ROOST" gate
    [ "$status" -eq 0 ]
    # `restrict` first: no shell, no pty, no agent — and then one forward back on.
    [[ "$output" == *'restrict,port-forwarding,permitlisten="127.0.0.1:18130"'* ]]
    [[ "$output" == *"AAAAKEY"* ]]
}

@test "the gate's vhost proxies into the forward's own end, on loopback" {
    write_conf
    printf 'gate=roost-tunnel@gate.example\npublic_host=terminal.example\n' >> "$ROOST_CONF"
    gate_state
    run "$ROOST" gate
    [[ "$output" == *"proxy_pass http://127.0.0.1:18130;"* ]]
    [[ "$output" == *"server_name terminal.example;"* ]]
    # The header the terminal's Origin check depends on.
    [[ "$output" == *'proxy_set_header Host $http_host;'* ]]
    [[ "$output" != *'proxy_set_header Host $host;'* ]]
    # nginx's own variables must survive the shell, not be expanded by it.
    [[ "$output" == *'map $http_upgrade $roost_connection_upgrade'* ]]
}

@test "printing changes nothing on the gate" {
    write_conf
    printf 'gate=roost-tunnel@gate.example\n' >> "$ROOST_CONF"
    gate_state
    run "$ROOST" gate
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing was changed"* ]]
    ! grep -q "ssh " "$STUB_LOG" 2>/dev/null || true
}

@test "the certificate lock reaches the gate's vhost too, with the authority to copy" {
    write_conf
    printf 'gate=roost-tunnel@gate.example\npublic_host=terminal.example\nclient_auth=mtls\n' >> "$ROOST_CONF"
    gate_state
    run "$ROOST" gate
    [[ "$output" == *"ssl_verify_client      optional;"* ]]
    [[ "$output" == *"ssl_crl"* ]]
    # The front asking for certificates is the gate's nginx now, so the authority
    # has to be there — and the revocation list has to travel again on each
    # revocation, which is the part that is easy to forget.
    [[ "$output" == *"ca.crl"* ]]
    [[ "$output" == *"revoked"* ]]
}

@test "the gate cannot be described before the stand has a tunnel" {
    write_conf
    printf 'gate=roost-tunnel@gate.example\n' >> "$ROOST_CONF"
    export ROOST_TUNNEL_STATE="$BATS_TEST_TMPDIR/absent.env"
    run "$ROOST" gate
    [ "$status" -ne 0 ]
    [[ "$output" == *"roost tunnel"* ]]
}

@test "an unknown gate option is refused" {
    write_conf
    printf 'gate=roost-tunnel@gate.example\n' >> "$ROOST_CONF"
    gate_state
    run "$ROOST" gate --sideways
    [ "$status" -ne 0 ]
}

@test "doctor calls out a tunnel that is not holding" {
    cat > "$ROOST_CONF" <<CONF
egress_profile=direct
agent_command=/usr/bin/true
CONF
    gate_state
    STUB_RC=1 run "$ROOST" doctor
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not up"* ]]
    [[ "$output" == *"roost gate"* ]]
}

@test "doctor is satisfied when it is" {
    cat > "$ROOST_CONF" <<CONF
egress_profile=direct
agent_command=/usr/bin/true
CONF
    gate_state
    run "$ROOST" doctor
    [[ "$output" == *"the tunnel to roost-tunnel@gate.example is up"* ]]
}

# --- the environment repository, and rotating the token ------------------

@test "the environment repository reaches the role that lays it out" {
    write_conf
    printf 'env_repo=https://git.example/dotfiles.git\nenv_branch=master\nproject_dir=/home/x/work\n' >> "$ROOST_CONF"
    run "$ROOST" install
    [ "$status" -eq 0 ]
    grep -q "env_sync_repo=https://git.example/dotfiles.git" "$STUB_LOG"
    grep -q "env_sync_version=master" "$STUB_LOG"
    # Beside the projects, not in a path the role guessed from a home directory:
    # project_dir is configurable and the environment has to follow it.
    grep -q "env_sync_dir=/home/x/work/dotfiles" "$STUB_LOG"
}

@test "no environment repository is not an error, just nothing to lay out" {
    write_conf
    run "$ROOST" install
    [ "$status" -eq 0 ]
    grep -q "env_sync_repo=" "$STUB_LOG"
}

@test "rotating the token needs a terminal to rotate it for" {
    write_conf
    export ROOST_TERMINAL_STATE="$BATS_TEST_TMPDIR/absent.env"
    run "$ROOST" token --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"nothing to rotate"* ]]
}

@test "rotating the token asks before it costs every phone its link" {
    write_conf
    export ROOST_TERMINAL_STATE="$BATS_TEST_TMPDIR/terminal.env"
    printf 'TERMINAL_LISTEN=127.0.0.1:8130\n' > "$ROOST_TERMINAL_STATE"
    run "$ROOST" token < /dev/null
    [ "$status" -ne 0 ]
    # Matched on one line of it: the sentence wraps, and a pattern spanning the
    # break fails for reasons that have nothing to do with the warning.
    [[ "$output" == *"Every device holding the old link"* ]]
}

@test "rotating replaces the line rather than adding a second one" {
    write_conf
    export ROOST_TERMINAL_STATE="$BATS_TEST_TMPDIR/terminal.env"
    export ROOST_TERMINAL_ENV="$BATS_TEST_TMPDIR/pockterm.env"
    export ROOST_POCKTERM_BIN="$STUB_DIR/pockterm"
    printf 'TERMINAL_LISTEN=127.0.0.1:8130\n' > "$ROOST_TERMINAL_STATE"
    printf 'POCKTERM_TOKEN=old-token\nPOCKTERM_SESSION_DIR=/home/x/work\n' > "$ROOST_TERMINAL_ENV"
    # The terminal mints the token; roost only puts it where the service reads it.
    printf '#!/usr/bin/env bash\ncase "$1" in token) echo new-token ;; qr) echo "QR for $POCKTERM_TOKEN" ;; esac\n' \
        > "$STUB_DIR/pockterm"
    # sudo runs the rewrite as root on a real stand; here it runs the same
    # command as the test user.
    printf '#!/usr/bin/env bash\nexec "$@"\n' > "$STUB_DIR/sudo"
    chmod +x "$STUB_DIR/pockterm" "$STUB_DIR/sudo"
    export ROOST_EXPOSE_STATE="$BATS_TEST_TMPDIR/expose.env"
    printf 'EXPOSE_URL=https://x:8443\n' > "$ROOST_EXPOSE_STATE"

    run "$ROOST" token --yes
    [ "$status" -eq 0 ]
    [ "$(grep -c '^POCKTERM_TOKEN=' "$ROOST_TERMINAL_ENV")" -eq 1 ]
    grep -q '^POCKTERM_TOKEN=new-token$' "$ROOST_TERMINAL_ENV"
    # Everything else in that file is somebody's setting.
    grep -q '^POCKTERM_SESSION_DIR=/home/x/work$' "$ROOST_TERMINAL_ENV"
    # And the service has to be restarted, or the old token is still in effect.
    grep -q "systemctl restart pockterm" "$STUB_LOG"
    # The new code is printed, not left to be found.
    [[ "$output" == *"QR for new-token"* ]]
}

@test "rotating says the token is not the lock when certificates are" {
    write_conf
    printf 'client_auth=mtls\n' >> "$ROOST_CONF"
    export ROOST_TERMINAL_STATE="$BATS_TEST_TMPDIR/terminal.env"
    printf 'TERMINAL_LISTEN=127.0.0.1:8130\n' > "$ROOST_TERMINAL_STATE"
    run "$ROOST" token < /dev/null
    [[ "$output" == *"client certificates"* ]]
}
