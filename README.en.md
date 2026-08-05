# roost

[Русская версия](README.md)

An installer for a machine that runs CLI coding agents. Whatever you have — a
single-board computer, a mini PC, an old laptop, a VPS — gets a sandbox with a
predictable way out to the internet, the agent itself, tmux sessions per project,
your own checkouts, and a web terminal to reach all of it from a phone.

> **Status: work in progress.** Everything below is written and verified on real
> hardware; installation is idempotent and teardown returns the machine to how it
> started. What is not yet verified is said where it applies.

## Quick start

```bash
git clone https://github.com/hitromudr/roost && cd roost
./roost up
```

One command, in this order:

1. asks a few questions and writes the answers to `roost.conf`;
2. installs ansible, if it is missing;
3. installs the agent, if it is missing;
4. creates the sandbox group and the egress rules;
5. brings up the web terminal on loopback;
6. opens a way to it: a certificate and roost's own vhost — or a tunnel to a gate;
7. prints a QR code for your phone and runs `roost doctor`.

On the phone: scan the code, then "add to home screen" — the page behaves like an
app, in its own window without tabs.

Every step is also a command of its own, because each touches something the
machine may already have an owner for. `roost install` still means exactly what it
always did — sandbox, sessions, environment — and installs no web terminal.

## What ends up on the machine

| Part | What it is | Where |
|---|---|---|
| sandbox | the `agent-sandbox` group and `gid-owner` rules: out only through a proxy | `/usr/local/sbin/egress-firewall`, unit `egress-firewall` |
| launchers | `agent-run` (start the agent in the group) and `agent-exec` (start any command in it) | `/usr/local/bin` |
| agent | the agent binary, installed through that same proxy | `~/.local/bin/claude` by default |
| sessions | tmux sessions per project, `roost-<project>`, mouse mode for phones | `roost-session` |
| terminal | pockterm on loopback, installed by pockterm's own installer | unit `pockterm`, `/etc/pockterm` |
| way in | roost's own vhost and certificate — or a reverse tunnel to a gate | `/etc/nginx/conf.d/roost-terminal.conf` |
| state | what roost installed, so that teardown knows what to remove | `/etc/roost/*.env` |

## Commands

| Command | What it does |
|---|---|
| `roost up` | all of it in order: agent, sandbox, terminal, way in, QR |
| `roost setup` | questions; answers go to `roost.conf` |
| `roost install` | sandbox, sessions, environment |
| `roost agent` | installs the agent if it is missing; records the path it found |
| `roost terminal` | a web terminal — only where there is none |
| `roost expose` | TLS in front of the terminal, on this machine |
| `roost tunnel` | a reverse tunnel to a gate, for a machine with no address |
| `roost gate [--apply]` | prints (or installs) what the gate needs |
| `roost enroll <device>` | issues a client certificate for one device |
| `roost qr` | the QR code with the address and the token |
| `roost projects [--list]` | brings this machine up to `projects.conf` |
| `roost doctor` | checks the stand is what it claims to be |
| `roost uninstall [--purge]` | removes what roost installed |

## Configuration

All of it in `roost.conf`; `roost setup` writes it from your answers, and
[`roost.conf.example`](roost.conf.example) explains every line. The file is
gitignored: it holds one machine's addresses and credentials.

| Key | Default | Meaning |
|---|---|---|
| `egress_profile` | `pinned` | `pinned` — loopback only, out through a local proxy; `proxied` — plus named destinations; `direct` — no restrictions |
| `proxy_url` | empty | the proxy the agent goes out through. Written to `/etc/roost/agent-proxy.env` (0640) |
| `expected_exit` | empty | the address the agent's traffic **should** leave from. `doctor` compares |
| `agent_command` | empty | the agent binary. Empty means roost installs Claude Code and records the path here |
| `agents` | empty | further agents, `name:command`, comma-separated |
| `project_dir` | `~/work` | where projects live; sessions are named after directories here |
| `terminal` | `true` | whether to install the web terminal |
| `listen` | `127.0.0.1:8130` | the terminal's address. Loopback only |
| `gate` | empty | `user@host` of a machine with a public address, when this one has none |
| `public_host` | empty | the domain for your phone. Empty derives an `sslip.io` name from the machine's address |
| `tls_port` | `8443` | the TLS port. Not 443: on a machine that does anything, it already belongs to something |
| `client_auth` | `token` | the lock: `token` or `mtls` |
| `email` | empty | contact address for Let's Encrypt |

> **Check the exit address before you log an agent in.** A proxy that answers is
> not the same as a proxy that changes where you come from: a local `3proxy` on
> the same server sends the traffic out of that server's own address. A request
> from an address the provider does not expect is grounds for suspending the
> account. `roost doctor` prints the address it found and compares it with
> `expected_exit`; while that is empty it says there was nothing to compare
> against.

The `pinned` and `proxied` profiles with no `PROXY_URL` leave the agent with **no
network at all** — it fails on its first request, and `doctor` says so.

## Reaching it from a phone

The terminal always listens on loopback. One of two things serves it outward.

### The machine has an address of its own

```bash
./roost expose      # roost's own vhost in nginx, a Let's Encrypt certificate
./roost qr          # the code with the address and the token
```

You may have no domain: the name is then derived from the machine's address
through `sslip.io` (`203-0-113-5.sslip.io`), and the certificate is still a real
one — which is what lets the page be installed as an app.

### Behind NAT: a gate

This needs a second machine with a routable address. `gate=` says which:

```bash
# gate=roost-tunnel@vps.example
./roost tunnel        # on the stand: roost's own key and a unit holding one forward
./roost gate          # prints what to add on the gate
./roost gate --apply  # or installs it over your own ssh access
```

Three files named after roost appear on the gate, and one line:

| What | Why |
|---|---|
| a line in `authorized_keys` | `restrict,port-forwarding,permitlisten="127.0.0.1:18130"` — one forward and nothing else: no shell, no agent, no second port |
| `/etc/ssh/sshd_config.d/roost-tunnel.conf` | without it a hardened sshd refuses the forward |
| `/etc/nginx/conf.d/roost-terminal.conf` | serves the terminal through the forward |

The certificate is issued **on the gate**: it has the address, so it is what can
prove the name. The tunnel's account is created by the gate's owner — `--apply`
does not do that.

### The lock: a token or a certificate

| | `token` (default) | `mtls` |
|---|---|---|
| what holds the door | a string in the URL your phone saved | a client certificate on the device |
| how many steps | one: scan the QR | two: install the certificate, then open the terminal |
| where the secret lives | browser history and the front's logs | the phone's own store, not readable out of it |
| a lost phone | change the token, and reconnect every device | `roost-ca revoke <device>` — the others are untouched |

Give a device its certificate:

```bash
./roost enroll phone
```

That prints a QR code with a **one-time link** to the device's bundle, and the
password its importer will ask for. The link lives ten minutes, used or not.

Take a lost device back out:

```bash
sudo roost-ca revoke phone && sudo systemctl reload nginx
```

### The session buttons go through the sandbox

The buttons in the session drawer start the agent inside the sandbox group rather
than beside it. The join is two lines in the service's environment file: pockterm
declares `CLAUDE ?=` and `AGENT ?=` in its Makefile, and `?=` yields to the
environment. The Makefile stays pockterm's, the policy stays roost's. `doctor`
checks exactly this — buttons that work while sandboxing nothing look like
success.

## Projects and environment

`projects.conf` names the repositories that belong on **every** machine you work
from:

```
isearch  https://git.example/isearch.git
sorter   https://github.com/x/sorter.git  develop
```

`./roost projects` brings the machine it runs on up to that list — equally at home
on the stand and on your laptop. Nothing already there is overwritten: a checkout
with uncommitted work is named and skipped, so is a name held by a directory with
no `.git` in it, and the rest of the list is still checked out.

The environment (`env_sync`) works the same way: your config repository is put in
place and its own installer runs. If it carries encrypted files (`*.sops.*`), the
role insists the age key is present — without it the secrets stay encrypted while
the installer reports success.

## A second agent

```
agents=codex:/home/you/.local/bin/codex
```

`roost install` installs `/usr/local/bin/codex-safe` — a link to the same
`agent-run` — and `/etc/roost/agents/codex.env`, which names the binary and
nothing else. The group, the proxy and the profile stay the machine's: one policy
for every agent on it.

## Boundaries: what roost owns

**roost owns only what roost installed.** Four rules follow, and the code obeys
them:

1. **A terminal is installed only where there is none.** A `pockterm.service`
   without `/etc/roost/terminal.env` beside it is the mark of another owner, and
   the role stops and says what to do instead.
2. **roost owns files, not services.** One file is added to somebody else's
   nginx; `nginx -t` is asked before the reload, and the file is taken back out if
   it does not parse. The reload itself needs your say-so.
3. **What roost cannot own, it prints.** A front door there is no file to add to
   (Caddy over its admin API, somebody else's gate) gets a printed recipe.
4. **Everything added comes out by name.** Teardown reads the state files;
   pockterm is removed by its own uninstaller.

## Security model

The sandbox here is about predictable outbound traffic, not about containing
malicious code: the agent runs as your user and can do to your files exactly what
you can.

**A terminal hands a full shell to whoever reaches it.** Treat that address like
SSH. By default the door is held by a token behind TLS — enough to start; for a
permanent installation use client certificates (`client_auth=mtls`).

No secrets in the repository. Anything host-specific — proxy credentials,
addresses, the repository list — is configuration: `roost.conf`, `projects.conf`
and `ansible/inventory` are gitignored, and only their `.example` counterparts
travel.

## Development

```bash
make help              # list targets
make check             # lint and tests: shellcheck, ansible-lint, bats
make test-integration  # three suites in throwaway containers (needs docker)
```

The `projects` and `env_sync` roles are run for real against throwaway
directories — ansible is all they need. The container suites cover what cannot be
covered without root and a network:

| Suite | What it proves |
|---|---|
| `egress_container.sh` | direct egress rejected for the group, the local proxy still reachable, processes outside unaffected, re-applying changes nothing, no rules left after `clear` |
| `mtls_container.sh` | no certificate is refused, a certificate gets in, somebody else's is refused, the enrolment path stays open, a revoked certificate stops working |
| `tunnel_container.sh` | the forward holds, the gate reaches the terminal on the stand, the key gets neither a shell nor a second forward |

The roles use `ansible.builtin` only — no collections to install. Run playbooks
from the repository root: `ansible.cfg` is there.

## Removing it

```bash
./roost uninstall --dry-run   # show what goes and what stays
./roost uninstall             # asks for confirmation
./roost uninstall --purge     # plus the sandbox group and roost.conf
```

| Goes | Stays |
|---|---|
| the rules and their unit, the launchers, the session helper, `/etc/roost` | your projects and any running sessions |
| the web terminal (through its own uninstaller), the vhost file, the build toolchain | the agent binary, and whatever it is logged in as |
| the tunnel: its unit and its key | the certificate — it is still valid |
| the certificate authority and the enrolment directory | everything roost did not install |

For the gate's side, teardown prints what is left there: only its owner can
remove it.

## Why it is like this

The decisions that would otherwise look arbitrary.

**Why roost never becomes a second owner.** An early version installed the web
terminal itself, and on a machine that already had one it generated a second
token — one the reverse proxy in front knew nothing about. Every request answered
`401`, which a browser renders as a machine with no sessions, and an evening went
into finding out why. Two owners of one unit break it the first time they
disagree.

**Why the exit address is a check of its own.** The first stand set up from a
config file was pointed at a local proxy that answered — and came out of that same
machine's address. `pinned` there bought predictability but not separation, and no
test catches that.

**Why the certificate travels as a link rather than in the QR code.** A device's
bundle is 4.4KB and a QR code holds 2953 bytes, and a code that dense is not
something a phone reads off a screen. That is measured; `tests/ca.bats` fails if
it ever stops being true.

**Why the gate's half is printed.** roost has no state file there, does not know
what else that nginx serves, and must not be the thing that reloads it by
surprise.

**Why `install` did not grow into `up`.** Machines that already call `install`
must not acquire a web terminal on their next update.

The full record of decisions is in
[`docs/superpowers/specs/`](docs/superpowers/specs/).
