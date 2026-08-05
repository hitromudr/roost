# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## Overview

roost gives a machine you own — a Raspberry Pi, a mini PC, an old laptop, a
VPS — a confined place to run CLI coding agents: a group whose outbound
traffic has a fixed exit, a launcher that starts the agent inside it, tmux
sessions per project, the same checkouts and environment as your other
machines, and — since 2026-08-05 — a web terminal to reach them from a phone.

Design and rationale live in `docs/superpowers/specs/`. The 2026-08-02 spec
describes the original wider project; the parts of it that touched other
people's services were withdrawn on 2026-08-03 and the way in came back on
2026-08-05 under explicit ownership rules — see "Scope" below and the
2026-08-05 spec.

## Commands

```bash
make help     # list targets
make check    # lint and tests
```

On a machine being set up as a stand:

```bash
./roost up    # agent, sandbox, sessions, terminal, TLS front, QR code
```

The pieces are also one command each — `roost agent`, `roost terminal`,
`roost expose`, `roost qr` — because each touches something a machine may
already have an owner for.

## Scope

**roost owns only what roost installed.** This is the project's main
constraint and it was learned the expensive way: the `publish` role installed
pockterm on a machine that already ran one and gave it a second token, unknown
to the reverse proxy in front. Every request answered 401, which a browser
shows as a machine with no sessions. Two owners of one unit break it the first
time they disagree. `publish` and `gate` were removed on 2026-08-03 for that
reason.

**Reaching the terminal from a phone came back on 2026-08-05, in a shape the
rule allows** (`docs/superpowers/specs/2026-08-05-one-button.md`). What was
wrong was not the goal but the assumption: the old role took it for granted
that it owned the terminal, the unit and the front door everywhere it ran. The
roles that replaced it check instead, and the four rules they follow are what
keeps them honest:

1. **A terminal is installed only where there is none.** The `terminal` role
   refuses when `pockterm.service` exists without `/etc/roost/terminal.env`
   beside it — that state file is what "roost wrote this" means.
2. **roost owns files, not services.** `expose` adds one vhost file to an
   existing nginx, runs `nginx -t`, and takes the file back out if it does not
   parse — a broken file in `conf.d` blocks the owner's reloads of unrelated
   vhosts. The reload needs `expose_reload_allowed`, which the CLI asks about.
3. **What roost cannot own, it prints.** A front door held by something with no
   file to add to (Caddy over its admin API) gets a printed route, not a fight
   for the port.
4. **Everything added is removable by name.** Teardown reads the state files
   and removes what they list — and pockterm is removed by running pockterm's
   own uninstaller, so that project stays the owner of its files to the end.

`roost install` deliberately still means what it meant: sandbox, sessions,
environment. The machines already running it must not acquire a terminal on
their next update, so the new steps are their own commands and `roost up` is
the sequence.

## Architecture

Two kinds of machine, and the difference is smaller than it looks:

| Node | What it is |
|---|---|
| stand | a machine that runs agents: sandbox, sessions, projects, environment |
| workstation | a machine you work from: projects and environment, no sandbox |

Ansible roles:

- `egress_sandbox` (stand) — group-based egress policy (`gid-owner` rules) and
  the `agent-run` launcher. The core of the project. A second agent is a second
  name for that launcher (`codex-safe` → `/etc/roost/agents/codex.env`), not a
  second wrapper: one group and one policy for every agent on the machine,
  declared in `egress_sandbox_agents` (`agents=` in `roost.conf`). It also
  installs `agent-exec`, the same policy for a caller that supplies a whole
  command line rather than arguments — without it the terminal's custom
  buttons would start agents outside the sandbox while looking configured.
- `agent_cli` (stand) — the agent binary itself, through the proxy the sandbox
  will use, because a stand that cannot reach the provider directly cannot
  reach the installer either. An agent already on the machine is recorded, not
  replaced.
- `terminal` (stand) — pockterm on loopback, installed by running pockterm's
  own installer and never by reimplementing it. The join to the sandbox is two
  lines in the service's environment file: pockterm's session Makefile declares
  `CLAUDE ?=` and `AGENT ?=`, `?=` yields to the environment, so the Makefile
  stays pockterm's and the policy stays roost's with no third copy of either.
- `expose` (stand) — a TLS front for that terminal: roost's own nginx vhost on
  a port nobody holds, a Let's Encrypt certificate over the `:80` that is
  already there, and an sslip.io name derived from the machine's address when
  there is no domain. `proxy_set_header Host $http_host`, not `$host`: the
  terminal refuses a WebSocket upgrade whose Origin and Host disagree, and on a
  non-443 port only `$http_host` keeps the port.
- `agent_sessions` (stand) — tmux sessions per project, named `roost-<project>`.
- `projects` (any machine) — brings the machine it runs on up to the
  repository list in `projects.conf`. The list says what should be checked
  out, not which machine is the source. Skips checkouts with uncommitted work
  and names taken by something that is not a checkout.
- `env_sync` (any machine) — the environment repository and its installer,
  with an age-key check for repositories carrying encrypted files.

Run playbooks from the repository root — `ansible.cfg` there points at
`ansible/roles`. The roles use `ansible.builtin` only: no collections to
install, which matters on a machine running whatever ansible its distribution
ships.

## Tests

`tests/*.bats`. The wrapper and the shell scripts are tested with stubs; the
`projects` and `env_sync` roles are run for real by `ansible-playbook` against
throwaway directories — no docker, no root, skipped where ansible is absent
(CI installs ansible-lint, not ansible). `tests/integration/` needs docker.

**A suite that also runs on a stand is a suite that must not read the stand.**
Two tests passed in CI and failed on the machine the roles manage, both for the
same reason: the environment of a real session. `agent-run` exports every
`AGENT_*` variable it reads, and the environment outranks the config file by
design, so a test proving the file is read has to unset them (`AGENT_PROFILE`
was the one that bit). Likewise a test proving "pockterm is not installed"
cannot arrange that by leaving it out of `PATH` on a machine where it is
installed — hence `ROOST_POCKTERM_BIN`. When a new test asks "what happens when
X is missing", check first whether X is present here.

One `--check` result to read past: `Enable tmux mouse mode for the user` is
reported as changing `~/.tmux.conf` from mode 0777 to 0644 on a machine where
that path is a **symlink** into a dotfiles repository. 0777 is the link's own
mode, which is what `lineinfile` sees in check mode; a real run follows the link
to the 0644 file behind it, finds the line already there, and reports
`changed: false` without touching either. Measured on 2026-08-05, both ways,
against a throwaway fixture — the alarming diff is a check-mode artefact, not a
world-writable config and not a second owner for a file dotfiles keeps.

## Conventions

Code comments, technical documentation and commit messages are in English.
User-facing documentation is bilingual: `README.md` (Russian) and
`README.en.md` (English), linked from each other.

No secrets in the repository. Anything host-specific — proxy credentials,
addresses, the repository list — is configuration: `roost.conf`,
`projects.conf` and `ansible/inventory` are gitignored, their `.example`
counterparts are what travels.
