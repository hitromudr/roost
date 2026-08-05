# roost

[Русская версия](README.md)

A place where a CLI coding agent runs under supervision. A machine you already
own — a single-board computer, a mini PC, an old laptop, a VPS — gets a group
with a predictable way out to the internet, a launcher that starts the agent
inside it, tmux sessions per project, the same checkouts and environment as
every other machine you work from, and — since 2026-08-05 — a web terminal to
reach all of it from a phone.

> **Status: work in progress.** Traffic confinement, sessions, environment
> sync, project checkouts, the `roost` wrapper and teardown are written and
> verified on real hardware (a Raspberry Pi): the second run is idempotent,
> the sandbox group and its rules appear, and teardown leaves no files and no
> rules in either address family. Installing the agent, the terminal and the
> way in came on 2026-08-05.

## Quick start

```bash
git clone https://github.com/<owner>/roost && cd roost
./roost up
```

One command, because every step in it would have to happen anyway: ask a few
things and write the answers to `roost.conf`, install ansible if it is missing,
install the agent if it is missing, create the group and the rules, bring up a
web terminal on loopback, obtain a certificate, add one vhost of its own — and
print a QR code. Point a camera at it, choose "add to home screen", and the
terminal behaves like an app.

The steps also exist one at a time, because each touches something the machine
may already have an owner for:

```bash
./roost setup      # questions; answers go to roost.conf
./roost agent      # install the agent, if this machine has none
./roost install    # sandbox, sessions, environment
./roost terminal   # a web terminal — only where there is none
./roost expose     # TLS in front of it, and the address it got
./roost qr         # the QR code for your phone
./roost doctor     # check the sandbox is what it claims to be
```

`install` deliberately still means what it meant: sandbox, sessions,
environment. Machines that already call it must not acquire a web terminal on
their next update.

The `pinned` and `proxied` profiles need `PROXY_URL` in
`/etc/roost/agent-proxy.env` (0640, owned by the agent's account). Without it
the agent has **no network at all**, and `doctor` says so in as many words.
`roost setup` asks for the proxy up front, so that file is not left as
homework — or write the answers yourself: `roost.conf.example` sits next to it
and explains every line.

> **Check the exit address before you log an agent in.** A proxy that answers
> is not the same as a proxy that changes where you come from: a local 3proxy
> on the same server sends the traffic out of that server's own address. To a
> provider, a request from an address it does not expect is grounds for
> suspending the account, and that costs more than an afternoon of debugging.
> `roost doctor` prints the address it actually found and compares it with
> `expected_exit` from `roost.conf`; while that is empty it says there was
> nothing to compare against.

## From a phone

`roost expose` puts TLS in front of the terminal on the same machine: its own
vhost file in nginx, a Let's Encrypt certificate, and a port nobody holds
(`8443` by default — on a machine that does anything, `443` almost always
belongs to something). You may have no domain at all: then the name is derived
from the machine's address through `sslip.io` (`203-0-113-5.sslip.io`), and
the certificate is still a real one — which is what lets the page be installed
as an app.

`roost qr` then prints the code: the address together with the token. The token
lives in the URL your phone saves, which means it also lives in browser history
and in the logs of whatever sits in front. For something you keep, put client
certificates there instead (see `deploy/nginx-mtls.conf.example` in pockterm);
a `.p12` does not fit in a QR code, so that part is not one button.

The buttons in the session drawer start the agent **through the sandbox**:
pockterm's Makefile declares `CLAUDE ?=` and `AGENT ?=`, `?=` yields to the
environment, and the service's environment is its env file. So the Makefile
stays pockterm's, the policy stays roost's, and no third copy of either appears.
`doctor` checks exactly this — buttons that work while sandboxing nothing look
like success.

### A second agent is another name, not another wrapper

The `agents=` line in `roost.conf` lists the rest of them, `name:command`,
comma-separated:

```
agents=codex:/home/you/.local/bin/codex
```

`roost install` then installs `/usr/local/bin/codex-safe` — a link to the same
`agent-run` — and `/etc/roost/agents/codex.env`, which names the binary and
nothing else. The group, the proxy and the profile stay the machine's: one
policy for every agent on it, rather than a copy per agent. A wrapper per agent
would be a copy of that policy per agent, and copies drift apart.

## What the roles do

| Role | What |
|---|---|
| `egress_sandbox` | the group, `gid-owner` rules, the agent launchers |
| `agent_cli` | the agent binary itself, where the machine has none |
| `agent_sessions` | tmux sessions per project, mouse mode for phones |
| `projects` | checkouts of the repositories in `projects.conf` |
| `env_sync` | the environment repository and its installer |
| `terminal` | a web terminal on loopback — where there is none |
| `expose` | TLS in front of it: roost's own vhost and certificate |

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

The third problem — reaching the machine from a phone — is solved by the same
run, under the rules below: alongside what the machine already has, never
instead of it.

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

So the way in, which came back to the project in 2026-08, works like this:

- **A terminal is installed only where there is none.** A `pockterm.service`
  without `/etc/roost/terminal.env` beside it is the mark of another owner, and
  the role stops and says what to do instead.
- **roost owns files, not services.** One file is added to somebody else's
  nginx, `nginx -t` is asked before the reload, and the file is taken back out
  if it does not parse: a broken file in `conf.d` breaks not only the terminal
  but every reload of the neighbouring vhosts. The reload itself needs your
  say-so, which is what `roost expose` asks for.
- **What roost cannot own, it prints.** Where the front door is held by
  something there is no file to add to — Caddy configured over its admin API,
  say — it prints the route to add and stops there.
- **Everything added comes out by name.** Teardown reads the state files and
  removes what they list; pockterm is removed by running **its own**
  uninstaller, so its files have one owner right to the end.

## Security model

The agent sandbox here is about predictable outbound traffic, not about
containing malicious code: the agent runs as your user and can do to your
files exactly what you can.

**A terminal hands a full shell to whoever reaches it.** Treat that address
like SSH — whether you serve the sessions with something of your own or with
`roost expose`. By default the door is held by a token behind TLS: enough to
start, and what makes the first run a single command. The token lives in the
URL, so it also lives in browser history and in the front's logs. For a
permanent installation, put client certificates in front.

## Development

```bash
make help     # list targets
make check    # lint and tests
```

The `projects` and `env_sync` roles are covered by tests that run them for
real against throwaway directories — ansible is all they need, no docker and
no root. Where ansible is absent, those tests skip.

`make test-integration` proves the policy itself in a throwaway container:
direct egress rejected for the group, the local proxy still reachable, processes
outside the group unaffected, re-applying changes nothing, and no rules left in
either address family after `clear`. It needs docker.

What no test can answer is which address the agent leaves from. `roost doctor`
asks that, and on a machine whose proxy you did not set up yourself it is the
line to read first: an unexpected exit address costs an account, not an
afternoon.

## Removing it

```bash
./roost uninstall --dry-run   # show what goes and what stays
./roost uninstall             # asks for confirmation
./roost uninstall --purge     # plus the sandbox group and roost.conf
```

What goes: the rules and their unit, the launchers, the session helper,
`/etc/roost`, and — if roost installed them — the web terminal (through its own
uninstaller), the vhost file and the toolchain downloaded to build it. What
stays: your projects and any running sessions (removing those should be a
decision, not a default), the agent binary along with whatever it is logged in
as, the certificate (still valid), and everything roost did not install.

Verified in a container: after teardown no rules remain in either address
family, and the machine is back to how it started.
