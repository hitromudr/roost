# roost

[Русская версия](README.md)

A place where a CLI coding agent runs under supervision. A machine you already
own — a single-board computer, a mini PC, an old laptop, a VPS — gets a group
with a predictable way out to the internet, a launcher that starts the agent
inside it, tmux sessions per project, and the same checkouts and environment
as every other machine you work from.

> **Status: work in progress.** Traffic confinement, sessions, environment
> sync, project checkouts, the `roost` wrapper and teardown are written and
> verified on real hardware (a Raspberry Pi): the second run is idempotent,
> the sandbox group and its rules appear, and teardown leaves no files and no
> rules in either address family.

**What roost does not do: get you to the machine from outside.** No web
terminal, no tunnel, no public entry point — that is a separate job with its
own owners. Sessions here are plain tmux, so anything that speaks tmux works:
[pockterm](https://github.com/hitromudr/pockterm) as a web terminal, `ssh -t`,
`mosh`, whatever you prefer. This followed from roost and an already-installed
web terminal fighting over the same systemd unit; see "Boundaries".

## Quick start

```bash
git clone https://github.com/<owner>/roost && cd roost
./roost setup      # a few questions; answers go to roost.conf
./roost install    # apply to this machine
./roost doctor     # check the sandbox is what it claims to be
```

The `pinned` and `proxied` profiles need `PROXY_URL` in
`/etc/roost/agent-proxy.env` (0640, owned by the agent's account). Without it
the agent has **no network at all**, and `doctor` says so in as many words.

## What the roles do

| Role | What |
|---|---|
| `egress_sandbox` | the group, `gid-owner` rules, the agent launcher |
| `agent_sessions` | tmux sessions per project, mouse mode for phones |
| `projects` | checkouts of the repositories in `projects.conf` |
| `env_sync` | the environment repository and its installer |

The roles use `ansible.builtin` only — no collections to install first.

### Projects: a list, not a handover

`projects.conf` names the repositories that belong on **every** machine you
work from:

```
isearch  https://git.example/isearch.git
sorter   https://github.com/x/sorter.git  develop
```

`./roost projects` brings the machine it runs on up to that list. What the
machines share is the repository, not one of them, so the command belongs
equally on the machine running agents and on your laptop.

Nothing already there is overwritten. A checkout with uncommitted work is
named and skipped; so is a name held by a directory with no `.git` in it — an
unpacked artefact, a deployment target — and the rest of the list is still
checked out. Leave the branch out to follow the repository's default.

The environment works the same way: `env_sync` puts your config repository in
place and runs its own installer. If that repository carries encrypted files
(`*.sops.*`), the role insists the age key is present — without it the secrets
stay encrypted while the installer reports success.

Run playbooks from the repository root — `ansible.cfg` there points at
`ansible/roles`.

## Why

Working with an agent ties you to the machine it runs on. Close the laptop and
the work stops. Moving the agent to a machine that stays on is easy enough,
but two problems surface that everyone then solves from scratch:

- **Reaching the internet.** The agent needs its API. If the server changes
  networks or sits behind NAT, its external address drifts. roost confines the
  agent's traffic to a group allowed to talk to a local proxy and nothing
  else, so the exit stays the same wherever the machine is.
- **The environment.** An agent is useful in proportion to how well it knows
  your setup: config, keys, project context. roost lays these out the same way
  on every machine and keeps the secrets encrypted.

The third problem — reaching the machine from outside — is deliberately left
to other tools.

## Boundaries

A machine that runs agents is rarely empty: it already has a web terminal,
tunnels, units of its own and a history. One rule follows from that: **roost
owns only what roost installed.**

That is not tidiness. An early version installed the web terminal itself, and
on a machine that already had one it generated a second token — one the
reverse proxy in front knew nothing about. Every request answered `401`, which
a browser renders as a machine with no sessions, and an evening went into
finding out why. Two owners of one unit break it the first time they disagree,
and the only reliable defence is not to become the second one.

So `roost uninstall` takes out the rules, the launcher, the session helper and
`/etc/roost` — and touches nothing else, however much it looks like part of
the same picture.

## Security model

The agent sandbox here is about predictable outbound traffic, not about
containing malicious code: the agent runs as your user and can do to your
files exactly what you can.

If you serve these sessions to the outside with something else, remember that
**a terminal hands a full shell to whoever reaches it.** Treat that access
like SSH.

## Development

```bash
make help     # list targets
make check    # lint and tests
```

The `projects` and `env_sync` roles are covered by tests that run them for
real against throwaway directories — ansible is all they need, no docker and
no root. Where ansible is absent, those tests skip.

## Removing it

```bash
./roost uninstall --dry-run   # show what goes and what stays
./roost uninstall             # asks for confirmation
./roost uninstall --purge     # plus the sandbox group and roost.conf
```

What goes: the rules and their unit, the launcher, the session helper and
`/etc/roost`. What stays: your projects and any running sessions — removing
those should be a decision, not a default — and everything roost did not
install.

Verified in a container: after teardown no rules remain in either address
family, and the machine is back to how it started.
