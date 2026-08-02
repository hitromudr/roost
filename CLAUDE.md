# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## Overview

roost turns a machine you own — a Raspberry Pi, a mini PC, an old laptop, a
VPS — into a stand for CLI coding agents. Agents live in tmux sessions there,
their outbound traffic is confined to a group with a fixed exit, and the whole
thing is reachable from a phone through a web terminal.

Design and rationale live in `docs/superpowers/specs/`.

## Commands

```bash
make help     # list targets
make check    # lint and tests
```

## Architecture

Three nodes:

| Node | What it is | Required |
|---|---|---|
| stand | the machine agents run on, usually behind NAT | yes |
| gate | public entry point with a routable address | no, if the stand is public |
| workstation | the machine you work from | yes |

Four ansible roles, driven by the `roost` wrapper:

- `egress_sandbox` — group-based egress policy (`gid-owner` rules) and the
  `agent-run` launcher. The core of the project.
- `agent_sessions` — tmux sessions per project, naming, restart policy.
- `publish` — reverse tunnel to the gate, TLS and authentication in front.
- `env_sync` — shell/editor config, secrets and agent context across machines.

## Conventions

Code comments, technical documentation and commit messages are in English.
User-facing documentation is bilingual: `README.md` (Russian) and
`README.en.md` (English), linked from each other.

No secrets in the repository. Anything host-specific — proxy credentials,
tokens, addresses — is configuration: documented in the README, stored in
files with 600 permissions on the target machine, never committed.
