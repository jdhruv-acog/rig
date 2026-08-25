# Design

rig takes a machine from nothing to ready. This is the reasoning behind how it
does that. The rules below hold everywhere in `rig.sh`; when a line looks odd,
one of them is why.

## Three gates, in order

A new machine has to pass three access checks, and they are different in kind.
rig separates them and takes them in this order.

**1. Public.** `curl`, `tar`, `unzip`, git, and the toolchain — gh, bun, uv,
Python, node. Everything here is downloaded from a public address. No account,
no organisation, no token. A run with no pack name uses only this gate, which is
why `curl -fsSL https://<host>/rig.sh | sh` works for anybody.

**2. GitHub organisation membership.** The sign-in. rig runs `gh auth login`,
which opens a browser and asks GitHub who you are. This proves nothing about the
machine and everything about the account.

**3. The private repository.** The clone. This is the gate that decides whether
the account can have the packs.

The order matters, and gate 3 runs before the toolchain install rather than
after. Gate 3 is the one most likely to refuse. Finding out in fifteen seconds is
better than finding out after a three minute install that was never going to be
useful. It costs one clone of a small repository.

A refusal at gate 3 arrives from GitHub as a bare 404, and that has two very
different causes: the account is not in the organisation, or it is the wrong
account. rig names the account that was refused and gives the command for each
cause. A 404 by itself is not something a person can act on.

## rig is never installed

There is no `rig` on disk after a run. It is one file, fetched with `curl`, run
once, and gone.

That is not minimalism. An installed bootstrapper has a version on the machine,
and that version is a copy of a moment in the past. It needs a self-update path,
the self-update path needs its own bootstrap, and the day somebody reports a bug
you have to ask which of the four versions on their machine ran. A script that
lives only at a URL is always the current one. There is nothing to go stale,
nothing to update, and nothing to ask about.

It is POSIX `sh` for the same kind of reason: macOS ships bash 3.2 from 2007, and
Debian's `/bin/sh` is dash. The one interpreter that is certainly present is the
one it is written for.

## Check, act, check again

Every stage does three things in this order: ask whether the result is already
true, do the work if it is not, and confirm the result afterwards.

That is the whole of rig's idempotency. It is not a state file, not a lock, and
not an "installed" flag — a flag can disagree with the disk, and when it does
it is the flag that gets believed. Asking the machine cannot disagree with the
machine.

Two consequences follow, and they are the ones a user sees:

- A second run does nothing, and says so. Each stage reports "already here"
  rather than reinstalling.
- An interrupted run is finished by running the same line again. There is no
  repair mode, no `--continue`, and no cleanup step, because a half-finished run
  is indistinguishable from a machine that was always partly ready.

The final check is not optional politeness. `ensure_gh` runs the binary it just
unpacked; `ensure_node` runs `node --version`; `ensure_python` asks uv to find
the exact version required, not whether some Python exists. A step that installed
something which will not run has failed, and it must say so at the point of
failure rather than three stages later.

## The manifest, and what is not in it

`rig/manifest` is a tab-separated file. It records only what rig installed, and
only things that can be removed.

There is no "already here" line and no state column. Absent means not ours. That
makes the removal rule one sentence — *remove what is listed, touch nothing else*
— and a one-sentence rule cannot be misread at two in the morning.

This is the entire difference between an uninstaller and a mess. If bun was
already on the machine when rig ran, rig uses it and records nothing. The
uninstaller then cannot remove it, because it is not there to be found. An
uninstaller that instead guesses from paths deletes somebody's own bun and calls
it cleanup.

Two entries are deliberately absent:

- **Apple's Command Line Tools.** They are system-wide, they serve every account
  on the machine, and removing them needs an administrator. rig will not undo
  something it had to borrow a password for.
- **Anything rig found rather than installed.** Covered above.

An unchanged entry is left exactly as it is, timestamp included. The time in the
manifest answers "when did rig install this". Rewriting it on every run would
turn it into "when did rig last run", which is a different and less useful fact.
It also makes the file byte-stable, which is what lets a test prove that a second
run changed nothing.

## Every write is compare, then rename

Two rules hold for every file rig touches.

**Rename into place.** The new content is written beside the target and moved
onto it. Rename is the one atomic filesystem operation. A power cut during a
rename leaves either the old file or the new one, never half of either. This is
why an interrupted rig run cannot truncate a `.zshrc`. The same rule covers
downloads: each one lands in a trapped temporary directory and moves in last, so
an interrupted fetch never leaves something that later looks installed.

**Compare first.** If the new content is identical to what is already there, the
temporary file is deleted and the target is not touched at all. Its modification
time stays where it was. That matters for a file the person also edits by hand,
and it is what lets `write_block` report whether it actually changed anything
instead of claiming work it did not do.

The shell block follows both rules. `write_block` rebuilds the file, dropping
everything between the two markers and appending the current block at the end, so
your own lines above and below survive every rerun and there is never a second
copy of the block.

`env.sh` is generated from what the run actually resolved, never from constants.
A tool's install directory varies by version and by what was already on the
machine, so rig asks — `bun pm bin -g` for bun's global directory, `find` for
uv's binary — and writes the answer. A path guessed at the top of a script
becomes a PATH entry that points at nothing.

`env.sh` itself runs no subprocess. It is read on every shell start, so it holds
literal paths only; a `bun pm bin -g` inside it would cost a process on every
prompt. Its last lines are an `if`, not an `&&`, because a trailing false `&&`
makes the file return non-zero, which exits any shell whose startup file runs
under `set -e`.

## Four kinds of failure, three exit codes

The codes are:

| Code | Meaning |
| --- | --- |
| 0 | done |
| 1 | a step failed |
| 2 | this request is not possible here |

The distinction is what a person can do next. **2** means stop asking: this
machine, or this account, cannot do the thing, and something outside rig has to
change. **1** means it can, and it did not.

The four kinds of failure map onto them:

**This machine cannot.** An unsupported operating system or architecture; no
`curl`, `tar` or `unzip`; Apple's Command Line Tools missing with nobody to type
a password. Exit 2. rig names what is missing and the command that installs it.

**The person declined, or is not permitted.** The Command Line Tools install was
refused; the GitHub sign-in was refused. Exit 2. Refusing is a legitimate answer,
and rig prints the shorter command that works without it.

**The network refused.** rig separates three cases that look identical in a bare
`curl` error, because the fix for each is different: a rejected certificate means
a proxy is inspecting TLS and somebody has to hand over its certificate; a
resolution failure means DNS, often a VPN filtering it; anything else is reported
with the reason curl gave. Exit 1.

**A step ran and did not produce the result.** A checksum mismatch; a binary that
was installed and will not run; a repository that is not visible. Exit 1. A
checksum mismatch is never retried and never tolerated — it means the bytes are
not the bytes that were pinned.

Every stop passes the fix along with the message. A refusal without a way out is
a defect, not a safety feature.

## Why `curl | sh` needs `exec < /dev/tty`

`curl -fsSL … | sh` puts a pipe on standard input. The shell reads the script
from that pipe, and by the time the script runs, standard input is that same pipe
— already consumed, and not a terminal.

Every prompt from that point on reads from the pipe, gets nothing, and returns
immediately. Apple's password prompt gets an empty answer. GitHub's browser
sign-in gets an empty answer. The run fails in a way that looks like the tool is
broken rather than like a missing terminal.

So rig reconnects standard input to the controlling terminal:

```sh
if [ ! -t 0 ] && ( : < /dev/tty ) 2>/dev/null; then
  exec < /dev/tty
fi
```

The probe is a subshell, and it is there because `/dev/tty` can exist and still
refuse to open — a detached session, a container with no controlling terminal. In
a subshell that failure can be silenced. Only after it succeeds does rig take the
terminal for real.

When there is no terminal, rig does not block. `confirm` returns the standard
answer immediately, because a machine with no terminal must never wait for input
that cannot come. The one thing that cannot be answered by default is the GitHub
sign-in; a non-interactive run that needs one stops and names `GH_TOKEN`.

## Asking everything first

Every question the run will ask is asked before anything is changed. A person
answers one or two prompts, walks away, and comes back to a finished machine.
Nothing after that point waits for input except the sign-in that a browser has to
complete.

This is why `ask_everything` runs before the first install step, and why it
checks the Command Line Tools and the GitHub session up front rather than letting
each stage prompt when it gets there. A three minute install that stops halfway
to ask a question is a three minute install nobody watched.

## One block, one file, one PATH

Three installers each appending their own line to a startup file is how PATH
order becomes an accident nobody can debug. So each vendor installer is given its
own target directory and told not to touch shell files: `BUN_INSTALL` with
`SHELL=/bin/false`, `UV_NO_MODIFY_PATH=1`, `UV_PYTHON_INSTALL_DIR`. rig writes
`env.sh`, and the shell block reads `env.sh`. That is the only place PATH is
decided.

The last lines of `env.sh` add the command repository's `bin` directory when it
exists. That is why the handed-over tool needs no shell block of its own.

Which file gets the block depends on the shell. On macOS a bash login shell reads
`.bash_profile` and never `.bashrc`, so a block written only to `.bashrc` appears
to do nothing there. rig puts the block in `.bashrc` and makes `.bash_profile`
read `.bashrc` — the arrangement everything else already assumes, applied once
rather than left to the person.

## The handover

With a pack named, the last thing rig does is `exec`, not a call. The pack
installer owns the rest of the run and its exit code is the answer; an extra
shell layer in between can only lose information.

The absolute path is used for that `exec`, because the shell block has not taken
effect in this process. It is read by the *next* shell, not this one.

## Nothing private in this file

`rig.sh` holds no company name, no hostname, no package name and no product
name. The pack argument is a word it carries and never interprets, which is what
makes the script publishable at all.

That property is invisible in the source — nothing about a missing string draws
attention to itself — so it is checked instead of trusted.
`scripts/check-clean.sh` greps the tree for a list of forbidden strings and fails
the build on a hit. Anything that has to stay is a single narrow allowlist entry
that names the file and the line and says why, never a blanket exclusion, so the
list shrinks visibly and a new occurrence still fails.
