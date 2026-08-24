# rig — design

`rig` makes a machine ready. It installs the tools, it gets access to the private
registries, and it sets up a product. It can undo all of it.

Written in Simplified Technical English.

---

## 1. The one idea

**A machine has capabilities. A capability can be checked, applied, and removed.**

Everything in `rig` is that shape. The tool floor is a set of capabilities. Registry
access is a set of capabilities. A product is a set of capabilities. There is one engine,
and everything else is data.

```ts
interface Step {
  id: string;
  requires: string[];
  check(ctx): Promise<Verdict>;    // never writes
  apply?(ctx): Promise<void>;      // runs only when check says "missing"
  remove?(ctx): Promise<void>;     // undoes only what rig applied
}
```

| Command | What the engine does |
|---|---|
| `rig doctor` | every `check`, and nothing else |
| `rig install` | `check`, then `apply`, in dependency order |
| `rig remove` | `remove`, in reverse order, **only for steps rig applied** |

`doctor` and `install` call the same `check`. So the report and the action can never
disagree. A second run applies nothing, because `check` answers "is this true now".

---

## 2. What rig knows, and what it must not know

`rig` knows **kinds**. A site file and a product file supply the **data**.

```
   rig (public)                 site.yaml (yours)              product.yaml (yours)
   ────────────                 ─────────────────              ────────────────────
   how to write an npmrc        which registry host            which packages
   how to run docker login      which credential to ask for    which setup command
   how to make an SSH key       which GitHub organisation      which capability it needs
   how to install a tool        which tools, which versions
```

**`rig` contains no organisation name, no hostname, and no package name.** A test in CI
proves it. This is what makes the repository safe to publish and what makes a different
company able to use it with no fork.

---

## 3. The eight kinds

| Kind | What it does | Undo |
|---|---|---|
| `tool` | a runtime, through `mise` | remove the version |
| `npm-registry` | write the scope and the auth line in `~/.npmrc`, 0600 | remove those lines |
| `netrc` | write a `machine` entry in `~/.netrc`, 0600 | remove that entry |
| `docker-registry` | `docker login` | `docker logout` |
| `github-ssh` | make sure a key exists, and register it | never removes a key |
| `system-package` | ask, then use the platform's own way | ask, then remove |
| `container-runtime` | Colima on macOS. Podman or rootless Docker on Linux | stop and remove |
| `product` | install packages, then call the product's own setup | call the product's own remove |

A ninth kind is added only when no kind fits. A kind is a mechanism. A host is data.

---

## 4. Runtimes belong to `mise`

`mise` installs and pins runtimes on macOS, Linux and WSL, in user directories, with no
administrator password. It is one binary, and it has its own `doctor`.

`rig` installs `mise` and gives it the list from the site file. `rig` does not install
runtimes itself.

**Bun is the exception.** `install.sh` installs Bun, because `rig` is written in
TypeScript and must run before `mise` exists. Bun is the runtime of `rig`, not a managed
tool.

---

## 5. Privilege

A step that needs a password is **optional and separate**. It never blocks another step.

```
  Install it now?  [y/N/never]
```

| Answer | Now | Next run |
|---|---|---|
| `y` | apply it | check it |
| `N` | skip it | **ask again** |
| `never` | skip it | **do not ask** |

The answer goes in the state file. A person who answered `never` in March is not asked in
April. `rig doctor --ask <id>` reverses it.

`--yes` accepts every privileged step. `--no-privileged` refuses every one. Neither waits
for input.

---

## 6. Files

```
~/.config/rig/config.yaml        the site URL, and the answers to remember
~/.local/state/rig/state.json    what rig applied, and every "never"
```

`state.json` is the record that makes removal safe. `rig remove` reads it and undoes only
what `rig` did. A tool that was already on the machine is left alone.

Both files carry a schema version from the first release, so an old file is read correctly
or refused clearly. It is never misread.

---

## 7. Credentials

**`rig` reads a credential, uses it, and forgets it.** It stores a credential only where
the tool that needs it looks: `~/.npmrc`, `~/.netrc`, `~/.docker/config.json`. Each is
0600.

Four rules:

1. A password is read from the terminal with the echo off.
2. A password is **never** a command flag. A flag goes into shell history.
3. A password is never written to a log, on any channel.
4. With no terminal, a credential comes from the environment. `rig` does not wait for
   input that cannot arrive.

`rig` holds no credential of its own and has no store of its own.

---

## 8. Output

```
  ✓  it is true
  –  skipped, and the reason is given
  !  it works, and something is worth knowing
  ✗  it is wrong, and the fix is on the next line
```

- Progress goes to **stderr**. Results go to **stdout**. So `| jq` and `> file` behave.
- No spinners and no redraw. The output must stay readable in a CI log and over a slow
  connection.
- Colour only when stdout is a terminal, and never when `NO_COLOR` is set.
- `--json` on every command that reports a status.
- Exit codes: `0` all correct, `1` something is wrong, `2` the request is not possible.

Every failure names what is true, why that is a problem, and the command to run.

---

## 9. Limits

| | Supported |
|---|---|
| macOS 13 and later, Apple Silicon and Intel | yes |
| Linux, glibc, x86-64 and arm64 | yes |
| WSL2 | yes, as Linux |
| a container with no root | yes, with `curl` and `unzip` in the image |
| Alpine and musl | not yet |
| Windows, native | not yet |

An honest "not yet" is better than a broken yes.
