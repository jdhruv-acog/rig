# rig

Take a machine from nothing to ready, in one command.

```sh
curl -fsSL https://<host>/rig.sh | sh                  # the toolchain only
curl -fsSL https://<host>/rig.sh | sh -s -- <pack>     # the toolchain, then a pack
```

`<host>` is the address the script is published at. `<pack>` is the name of a
pack. rig carries that word to the command it hands over to and never interprets
it.

## What it does

1. Makes sure `git` works. On macOS this means Apple's Command Line Tools. This
   is the only step that asks for a password.
2. Downloads `gh` as a plain binary into the rig tree.
3. Signs the machine in to GitHub. This step runs only when a pack is named.
4. Clones the private command repository. This step runs only when a pack is
   named.
5. Installs the toolchain: bun, uv, Python and node.
6. Writes `env.sh`, which is the one place PATH is decided, and adds one marked
   block to your shell startup file that reads it.
7. Runs the pack installer and hands the rest of the run to it. With no pack
   name, rig stops after step 6.

rig is never installed. It is fetched, it runs once, and it is gone. There is no
copy on disk to go stale and no self-update path to maintain.

## Where it puts things

Everything lives in one tree under your home directory, written as `~/.<org>`
below. rig prints the real paths as it runs.

| Path | Contents |
| --- | --- |
| `~/.<org>/rig/bin/gh` | the GitHub CLI |
| `~/.<org>/rig/bun` | bun |
| `~/.<org>/rig/uv` | uv |
| `~/.<org>/rig/python` | the pinned Python |
| `~/.<org>/rig/node` | node |
| `~/.<org>/rig/env.sh` | the generated PATH file |
| `~/.<org>/rig/manifest` | the record of what rig installed |
| `~/.<org>/commands` | the private command repository |

Nothing is written to `~/.local`. That directory belongs to you, and a tool that
scatters into it cannot tell its own files from yours when it is removed.

One block goes into your shell startup file, between two marker comments. It has
one line in it, which reads `env.sh`. Your own lines above and below it survive
every rerun.

## What it does not do

- It does not install itself.
- It does not write outside the tree above and the one shell block.
- It does not use a package manager for the toolchain. Every tool is a pinned
  download into the tree. On Linux it uses `apt-get` for one thing only: `git`,
  when `git` is missing and `sudo` is available. See
  [docs/why-not.md](docs/why-not.md).
- It does not touch a tool you already have. If bun, uv or node is already on
  the machine, rig uses it, and does not record it, so removal leaves it alone.
- It does not need an administrator except to install Apple's Command Line
  Tools, and it never removes them.
- It does not interpret the pack name, and it holds no company name, no
  hostname and no package name. `scripts/check-clean.sh` proves that in CI.

## Running it again

Run the same line again. That is the whole recovery procedure.

Every stage asks whether it is already true before it acts, and checks the
result after. A second run changes nothing and says so. A run that was
interrupted — a closed laptop, a dropped network, a Ctrl-C — is finished by the
same command that started it. Every download lands in a temporary directory and
moves into place last, so an interrupted fetch never leaves something that later
looks installed.

## Options

Options come after `--` when the script is piped into `sh`.

```sh
curl -fsSL https://<host>/rig.sh | sh -s -- --help
```

| Option | Effect |
| --- | --- |
| `--yes`, `-y` | take the standard answer to every question, and ask none |
| `--version` | print the version and stop |
| `--help`, `-h` | print usage and stop |

Environment:

| Variable | Effect |
| --- | --- |
| `GH_TOKEN` or `GITHUB_TOKEN` | sign in with a token instead of a browser |
| `NO_COLOR` | print no colour |

With `--yes`, rig asks nothing. A GitHub sign-in cannot be answered by a
standard answer, so a run that needs one stops unless a token is set.

## Finishing

rig prints the path of the generated `env.sh` when it is done. Open a new
terminal, or read the file into the current one:

```sh
. ~/.<org>/rig/env.sh
```

## Removing it

```sh
curl -fsSL https://<host>/uninstall-rig.sh | sh
```

It reads the manifest and removes exactly what rig installed. Anything that was
on the machine before rig ran was never recorded, so it stays. Apple's Command
Line Tools stay: they are system-wide, they serve every account, and removing
them needs the password rig had to borrow.

The uninstaller stops when packs are still installed, because removing the
toolchain first strands them — a pack's own uninstall script needs the bun and
node that are about to disappear. It names the command that puts it in the right
order.

| Option | Effect |
| --- | --- |
| `--force` | remove the toolchain even when packs are still installed |
| `--yes`, `-y` | do not ask |
| `--help`, `-h` | print usage and stop |

## Platforms

Supported:

- macOS 13 and later, arm64 and x86-64. Under Rosetta an Apple Silicon Mac
  reports `x86_64`; rig detects that and installs the arm64 toolchain.
- Linux with glibc, arm64 and x86-64.
- WSL2.

Not supported:

- Alpine and other musl systems. The pinned node build is linked against glibc.
- Native Windows. Run rig inside WSL2.
- fish. rig writes no fish configuration. It prints the one line to add to
  `config.fish` by hand.

rig needs `curl`, `tar` and `unzip` before it can start. On Linux it names the
`apt-get` command that installs them and stops. On macOS these are part of the
system.

## Pinned versions

Pinned, not "latest". A bootstrap that installs a different thing each day
cannot be supported.

| Tool | Version | How it arrives |
| --- | --- | --- |
| gh | 2.98.0 | release archive, SHA-256 recorded in `rig.sh` |
| node | 24.19.0 | release tarball, SHA-256 recorded in `rig.sh` |
| bun | 1.4.0 | vendor installer over TLS, version pinned |
| uv | 0.12.5 | vendor installer over TLS, version pinned |
| Python | 3.14 | installed by uv, version pinned |

gh and node are downloaded as binaries, so their checksums are recorded and
verified. A mismatch stops the run and is never retried: it means the bytes are
not the bytes that were pinned. bun and uv are installed by their own vendor
installers, which detect the platform themselves; those carry a version pin and
no checksum.

To bump a pin:

1. Edit the version in the pinned versions block at the top of `rig.sh`.
2. For gh and node, replace the four SHA-256 values for that tool in
   `checksum_for`. There is one per platform: macOS arm64, macOS x64, Linux
   arm64, Linux x64.
3. Run the pin check (`tests/pins.sh`). It runs in CI and fails when a recorded
   checksum no longer matches what the vendor publishes, so a pin can go out of
   date but it can never go silently wrong.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | done |
| 1 | a step failed |
| 2 | this request is not possible here |

Every stop names the fix. A refusal with no way out is a defect.

## Reading further

- [docs/design.md](docs/design.md) — how rig is built, and why.
- [docs/why-not.md](docs/why-not.md) — the alternatives that were rejected, and
  the technical reason for each.
