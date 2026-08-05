# One button: from a clone to a terminal on a phone

Date: 2026-08-05.

## The problem this reopens

The 2026-08-02 design had three problems. Problem 2 — reaching the machine
from outside — was dropped on 2026-08-03 with the `publish` and `gate` roles,
after roost installed a web terminal on a machine that already ran one and
handed it a second token: every request answered 401, and a browser shows that
as a machine with no sessions.

The lesson was recorded as "roost owns only what roost installed", and it
stands. What was wrong was not the goal but the shape: the old `publish`
assumed it was the only owner of the terminal, the unit and the front door on
every machine it ran on. That assumption is false on any machine worth putting
an agent on.

So the goal comes back, and the ownership rule decides how far each step is
allowed to go:

    git clone … && cd roost && ./roost up

and the run ends with a QR code that opens a terminal on a phone, with the
agent already sandboxed behind it.

## What "one button" has to include

Measured on two real machines before writing any of this — a busy production host
and an almost-empty VPS, both of which someone else's services already occupy:

| Piece | Why it is missing today |
|---|---|
| ansible itself | neither has any; Debian 12 ships core 2.14, and the roles call `systemd_service` (core 2.16+). `./roost install` dies on its first line. |
| the agent | no `claude` on either machine, and no node. A sandbox around a binary that is not there is a session that closes the instant it opens. |
| the terminal | pockterm installs itself, but nothing brings it, points it at the sandbox, or tells it which Makefile starts a session. |
| the way in | `:80` and `:443` belong to somebody else on both machines. No cert, no vhost, no QR — and no honest way to add one without touching a service roost did not install. |

## Ownership, restated as rules the code follows

1. **roost installs the terminal only where there is none.** A
   `pockterm.service` roost did not write stops the run with what to do
   instead. The state file `/etc/roost/terminal.env` is what "roost wrote it"
   means; without it, the unit belongs to somebody else.
2. **roost owns files, not services.** On a machine that already runs nginx,
   roost writes its own vhost file and its own cert, then asks before
   reloading. `nginx -t` runs first: a bad file must not take the neighbours'
   vhosts down with it.
3. **What roost cannot own, it prints.** Caddy configured over its admin API
   is not a file roost can add to. There it prints the route to add and
   stops — a snippet the owner applies beats a second owner of :443.
4. **Every added piece is removable by name.** `roost uninstall` reads the
   state files and removes what they list, and nothing else.

## The path, and what each step is allowed to do

    ./roost up

1. **bootstrap** — ansible from the distribution's package manager when it is
   absent; `systemd` instead of `systemd_service` so core 2.14 is enough.
   Nothing else is installed behind the operator's back.
2. **sandbox** (`egress_sandbox`, unchanged) — the group, the rules, the
   launcher. Still the core of the project.
3. **agent** (`agent_cli`, new) — installs the agent binary through the proxy
   the sandbox will use, so a stand that cannot reach the provider directly
   still gets one. Refuses to guess: an agent that is already installed is
   left alone.
4. **sessions** (`agent_sessions`, extended) — the session Makefile the
   terminal's "+" button runs, with the agent launcher in it. This is the whole
   join between the phone and the sandbox: one variable, in one file.
5. **terminal** (`terminal`, new) — pockterm's own installer, never a
   reimplementation of it, guarded by rule 1.
6. **way in** (`expose`, new) — a TLS front for the terminal on this machine:
   roost's own nginx vhost on a port nobody holds, a Let's Encrypt certificate
   over the `:80` that is already there, and a hostname derived from the
   machine's address when there is no domain (`203-0-113-5.sslip.io`).
   Guarded by rules 2 and 3.
7. **qr** — `pockterm qr` with the public URL and the token, so the last line
   of the install is something to point a camera at.

## The lock on the door

Behind the URL is a full shell as the agent's account. Two levels, and the
first is not the end state:

- **token over TLS** — the default, because it is what makes the first run one
  command. The token is in the URL the phone saved, which means it is also in
  browser history and in the front's logs. Said in the output, not only in the
  README.
- **mutual TLS** — a client certificate on the phone. Stronger and not
  one-button: a `.p12` does not fit in a QR code. Second step, after the path
  above works end to end.

Nothing here is a reason to skip the sentence that has been in the README from
the start: treat this access as SSH.

## What is deliberately not in it

- **A gate.** A machine behind NAT still needs somewhere with a routable
  address, and that is the shape the old `gate` role had. Out until the
  single-machine path is proven; the design of it survives in the 2026-08-02
  spec.
- **An APK.** The owner's phone runs an Android client with the address
  compiled in; parameterising, publishing and signing it is a project of its
  own. The PWA installs from the QR link on any phone, which is what "one
  button" needs.
- **Anything on a machine roost was not pointed at.** No pushing to a second
  host, no editing another repository's roles.

## How it is verified

On the emptier of the two, from nothing: the tree, a `roost.conf`, `./roost up
--yes`. Debian 12, two cores, no ansible, no Go, no node, no tmux, no agent —
and `:80` and `:443`
already held by nginx and an xray endpoint that are not roost's.

What the run did, measured on 2026-08-05: installed ansible-core 2.14 from the
distribution, installed Claude Code through the proxy, created the group and
three `gid-owner` rules, downloaded a checksummed Go toolchain into
`/opt/roost/go`, cloned pockterm from GitHub and built it, put it on
`127.0.0.1:8130`, added `/etc/nginx/conf.d/roost-terminal.conf`, obtained a
Let's Encrypt certificate for that sslip.io name over the `:80` that was
already there, and printed a QR code. `EXIT=0`.

Then, from another machine over the internet rather than from the host itself:

- `GET /` → 200 with a valid certificate; `GET /api/sessions` without the token
  → 401, with it → 200. The static page is not behind the token by pockterm's
  own design; every API and the socket are.
- `POST /api/sessions/new` with `{"preset":"claude"}` — the phone's "+" button —
  → 204, and a session appeared.
- That session's process tree: `tmux → agent-run → sg agent-sandbox -c
  …/.local/bin/claude → claude`, with `Groups: … 1002` where 1002 is
  `agent-sandbox`, and `HTTPS_PROXY` set from the credentials file.
- From inside that group: direct to the provider → `000` (rejected by the
  rules), through the proxy → 401 (arrived).
- `nginx -t` still passes and the machine's own vhosts still answer 301 as
  before.

The third run of `roost up` reports `changed=0` from all four playbooks, which
is what "idempotent" has to mean here: a machine that is already a stand is left
alone, including its certificate and the terminal somebody may be sitting in.

Five defects were found by these runs rather than by the tests, which is the
point of running them:

1. `agent_cli` wrote its state file into `/etc/roost` before any role created
   that directory — it now creates it, because an agent has to exist before
   there is a point in sandboxing one.
2. `egress_sandbox` set the ownership of the credentials file before the task
   that creates it. That order only worked on a machine where somebody had
   already made the file by hand, which was every machine roost had run on.
3. `expose` used `backup: true`, which left
   `roost-terminal.conf.<pid>.<date>~` in somebody else's `conf.d` — a file
   nginx does not read and teardown did not know about. The previous version
   now goes to roost's own directory.
4. The Go toolchain was re-downloaded on every run: the unpack step was guarded
   by `creates` and skipped, so 70MB of compiler arrived and was deleted again
   without the recap saying anything interesting. The toolchain roost already
   put in its own directory is now looked for before deciding.
5. `version: HEAD` on the checkout made the git module report a change every
   run, because it cannot resolve that to a revision on the remote. The default
   branch is now asked for by name (`git ls-remote --symref`), which keeps
   `main` out of this repository — it is the wrong answer for every project
   still on `master`.

Then `roost uninstall --purge`, and `roost up` again on the same machine.

Teardown left: no rules in either address family, no group, no `/etc/roost`, no
units, no launchers, no pockterm binary, no vhost — `nginx -t` still passes and
the machine's own vhosts still answer. Kept, as the output says before it starts:
the certificate, the projects directory with pockterm's session Makefile in it,
the running tmux session, the agent binary, and `/etc/pockterm/pockterm.env` with
its token — which is why the reinstall produced the same URL and the phone's saved
link kept working.

Three more defects, all found by that cycle:

6. Teardown left `/var/www/roost-acme` and an empty `/opt/roost` behind — two
   directories with roost's own name on them. The challenge directory is now
   recorded as roost's (`EXPOSE_WEBROOT_OWNED`) so that a webroot the machine
   already served from is never deleted, and `/opt/roost` goes with `rmdir`,
   which declines when anything else is in it.
7. The reinstall re-issued nothing: certbot's `creates` guard saw the existing
   certificate, which matters because a rate limit is a poor way to learn about
   an eager installer.
8. `regex_search('…(\\S+)', '\\1')` written inside a `>-` block fails on
   ansible-core 2.14 — "AttributeError: 'NoneType' object has no attribute
   'group'" — while the same expression in a double-quoted scalar works. The
   ansible on the development machine (2.19) accepts both, so neither `make
   check` nor `ansible-lint` had anything to say; the target's own version found
   it in seconds. It would have broken a real teardown, not only `--check`.

What is deliberately not verified any further: nothing else is run as an
authenticated agent for the sake of a test. The chain from a phone's button to a
process in the sandbox group was proved once, on a machine where no agent had
ever logged in — the first run's own state file shows no credentials, so no
request carried an account — and the stand was then removed. A verification that
risks the account it is meant to protect is not a verification anyone should
repeat, and this project is about to be handed to people who would repeat it.

That is also why `roost doctor` now prints the exit address whether or not there
is anything to compare it against: on the machine used for these runs the local
proxy came out of the machine's own address, which the profile's promise of a
fixed exit says nothing about and which nothing in the project had ever asked.
