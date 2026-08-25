# Why not

Each entry names something rig does not use, and the concrete reason. If you are
about to add one of these, read the entry first. The reasons are mechanical, not
matters of taste, and they are still true.

## Why not Homebrew

Homebrew is the obvious way to install tools on macOS. It cannot do this job.

**On macOS it needs the Command Line Tools.** That is the same gate `git` needs.
Installing Homebrew so that rig does not have to require the Command Line Tools
requires the Command Line Tools. The circle does not close, and the password
prompt arrives either way — later, and from a tool the person did not ask for.

**A root-owned prefix is detected but unusable.** `/opt/homebrew` owned by root
is found by every check that looks for brew, and then every install into it
fails, because the prefix is not writable by the account running it. The failure
is not "Homebrew is missing", which is a state rig can repair; it is "Homebrew is
here and refuses", which needs an administrator and a decision about ownership of
a directory that other software on the machine already depends on.

**brew 6 and later prompts before installing.** It asks for confirmation unless
`HOMEBREW_NO_ASK` is set. A bootstrap run through a pipe has no answer to give
it. Depending on an environment variable to suppress an interactive prompt in
another project's tool is a dependency on that project's next release note.

**Casks target root-owned `/Applications`.** A cask install therefore needs a
password of its own, at an unpredictable point in the run.

**An application placed by anything other than Finder or a `.pkg` is not
registered.** Launch Services does not know about it. It does not appear in
Spotlight, `open -a` does not find it, and the default-application bindings do
not exist until `lsregister -f -R` is run over it by hand. An install that
appears to succeed and produces an application the person cannot launch is worse
than an install that refused.

rig downloads each tool as a pinned archive into a directory it owns. No prefix,
no privilege, no prompt from another tool, and no registration step.

## Why not nvm

nvm manages node versions. rig needs one node, at one version, on PATH. The two
are not the same problem, and nvm has four failure modes that all end with a
working install and a broken tool.

**`nvm use` substitutes in place; it does not prepend.** It replaces its own
previous entry in PATH at the position that entry already held. If a foreign node
— a system package, another version manager, something a container image put
there — is ahead of nvm's entry, it stays ahead after `nvm use` reports success.
The command says it worked, `node --version` disagrees, and nothing in the output
explains why.

**`default` and `lts/*` resolve to the newest node *installed*, not the newest
node.** They are aliases over the local set. A machine that has one old node
satisfies both aliases forever. There is no error, because nothing is wrong by
nvm's rules; the alias resolved exactly as designed, to the wrong thing.

**A global npm package belongs to the node version it was installed under.**
Global installs live inside the version directory. Upgrading node strands every
one of them: the package is on disk, it is not on PATH, and reinstalling it is a
step nobody remembers because nothing reported a failure.

**npm reports `EBADENGINE` as a warning.** A package that declares an engine
range the current node does not satisfy installs anyway. The exit code is 0. The
tool is on PATH. It fails the first time somebody runs it, in the tool's own
error vocabulary, far from the install that caused it.

A single pinned tarball, unpacked into a directory rig owns and prepended to
PATH, has none of these. There is one node, its version is the pinned constant,
its global packages cannot be stranded because the version does not move on its
own, and its directory is first in PATH because `env.sh` puts it there.

node is present for exactly one reason: tools published to npm carry a
`#!/usr/bin/env node` shebang and will not run without it. bun installs those
tools and cannot replace the interpreter they ask for.

## Why not `command -v` as a tool check on macOS

`command -v git` succeeds on a Mac with no developer tools installed. So does
`command -v python3`. Both are true and both are useless.

`/usr/bin/git` and `/usr/bin/python3` are the same binary. It is hardlinked 78
times across `/usr/bin`, one name per tool. That binary links
`libxcselect.dylib`, which resolves the active developer directory at exec time.
When there is no developer directory, it does not fail with "not found" — it
opens Apple's Command Line Tools installer dialog.

Two things follow:

- Being on PATH proves nothing. The path exists on every Mac, installed or not.
- A check that merely locates the tool can open a GUI dialog as a side effect,
  in the middle of a non-interactive run.

So rig runs the tool instead of locating it:

```sh
works() { command -v "$1" >/dev/null 2>&1 && "$@" >/dev/null 2>&1; }
```

and for the Command Line Tools specifically it asks `xcode-select -p` for a real
directory, then runs both `/usr/bin/git --version` and `/usr/bin/make --version`.
Output is discarded; only the exit status is the answer.

## Why not check admin group membership before installing the Command Line Tools

It looks like courtesy: find out whether the account can use `sudo`, and refuse
early with a clear message if it cannot.

It is wrong, because it misreads what `sudo` authenticates. On macOS, `sudo`
authenticates against the admin group, not against the current account. Any
account in that group can authorise the command. A person who is not an
administrator can turn the keyboard toward somebody who is, who types their own
password, and the install proceeds — which is exactly how a managed machine gets
set up in practice.

Checking group membership first, and refusing on that basis, blocks the case that
works. It converts a ten-second interruption into a support ticket, and the
message it prints ("you are not an administrator") is true and useless.

So rig states what is needed, and asks:

> Installing them needs an administrator password. If you are not an
> administrator, somebody who is can type it now.

The `sudo` prompt is then the only authority on whether it can proceed. That is
the one component that actually knows.

## Why not write it in TypeScript

The rest of the toolchain is TypeScript. This script is not, and the reason is
ordering.

A TypeScript program needs a runtime before it can run. rig's job is to install
that runtime. A bootstrapper written in the thing it bootstraps needs a
bootstrapper of its own, which is a shell script fetched with `curl` — the file
you are reading about, now with a second program behind it.

That second program would carry everything a program carries: a version on disk,
a place to install it, an update path, a dependency list, a lockfile, a build
step, and a release process. All of it for something that runs twice a year, once
per machine, for about three minutes.

POSIX `sh` runs on every target with nothing installed. It is the only language
that is already there, which for this one job is the only property that counts.
Everything after the handover is TypeScript.
