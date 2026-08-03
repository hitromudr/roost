# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## Overview

roost gives a machine you own — a Raspberry Pi, a mini PC, an old laptop, a
VPS — a confined place to run CLI coding agents: a group whose outbound
traffic has a fixed exit, a launcher that starts the agent inside it, tmux
sessions per project, and the same checkouts and environment as your other
machines.

Design and rationale live in `docs/superpowers/specs/`. The 2026-08-02 spec
describes a wider project — a stand including its own web terminal, tunnel and
public entry point; that scope was withdrawn on 2026-08-03, see "Scope" below.

## Commands

```bash
make help     # list targets
make check    # lint and tests
```

## Scope

**roost owns only what roost installed.** Serving sessions to the outside —
web terminal, tunnel, public entry point — is not part of it. Sessions are
plain tmux, so anything that speaks tmux can front them.

This is the project's main constraint and it was learned the expensive way:
the `publish` role installed pockterm on a machine that already ran one and
gave it a second token, unknown to the reverse proxy in front. Every request
answered 401, which a browser shows as a machine with no sessions. Two owners
of one unit break it the first time they disagree. The roles `publish` and
`gate` were removed on 2026-08-03 for that reason — do not reintroduce them,
and do not add tasks that touch units, files or services roost did not create.

## Architecture

Two kinds of machine, and the difference is smaller than it looks:

| Node | What it is |
|---|---|
| stand | a machine that runs agents: sandbox, sessions, projects, environment |
| workstation | a machine you work from: projects and environment, no sandbox |

Ansible roles:

- `egress_sandbox` (stand) — group-based egress policy (`gid-owner` rules) and
  the `agent-run` launcher. The core of the project.
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

## Conventions

Code comments, technical documentation and commit messages are in English.
User-facing documentation is bilingual: `README.md` (Russian) and
`README.en.md` (English), linked from each other.

No secrets in the repository. Anything host-specific — proxy credentials,
addresses, the repository list — is configuration: `roost.conf`,
`projects.conf` and `ansible/inventory` are gitignored, their `.example`
counterparts are what travels.
