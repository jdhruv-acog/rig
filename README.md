# rig

Make a machine ready. Install the tools, get access to the private registries, set up a
product. Undo all of it.

```sh
curl -fsSL https://<host>/install.sh | sh -s -- https://identity.example.com
```

One command. The deployment says which tools talk to it, so nobody is sent a list of
package names to paste.

No administrator password. No `git`. macOS, Linux, and WSL.

---

## What it does

```
rig setup <deployment-url>    make this machine ready for a deployment
rig base                      the runtimes only — nothing that needs a credential
rig doctor [deployment-url]   is this machine correct? Changes nothing
rig remove [deployment-url]   undo exactly what rig applied
```

Every command accepts `--json`. Every command is safe to run again.

## Starting over

```sh
curl -fsSL https://<host>/uninstall.sh | sh          # keeps your registry credential
curl -fsSL https://<host>/uninstall.sh | sh -s -- --all   # removes that too
```

It removes what rig installed and the PATH block it wrote, and leaves every other line
in your shell file exactly as it was.

## The one idea

A machine has capabilities. A capability can be checked, applied, and removed.

```ts
interface Step {
  id: string;
  requires: string[];
  check(ctx): Promise<Verdict>;    // never writes
  apply?(ctx): Promise<void>;      // runs only when check says "missing"
  remove?(ctx): Promise<void>;     // undoes only what rig applied
}
```

`rig doctor` runs every `check`. `rig install` runs `check`, then `apply`. It is the same
code, so the report and the action can never disagree, and a second run has nothing to do.

## rig knows nothing about your organisation

`rig` knows **kinds**: how to write an npmrc, how to run `docker login`, how to make an SSH
key. A **site file** says which host, which credential, and which products. That file is
yours and it stays private.

So this repository holds no company name, no internal address, and no private package name.
A test in CI proves it and fails the build on any hit:

```sh
sh scripts/check-clean.sh
```

Read [`examples/site.example.yaml`](examples/site.example.yaml) to see the shape.

## Runtimes belong to mise

`rig` installs [mise](https://mise.jdx.dev) and hands it the tool list from your site file.
It does not install runtimes itself. Bun is the one exception, because `rig` is written in
TypeScript and has to run before `mise` exists.

## A privileged step asks once

```
  Install it now?  [y/N/never]
```

`never` is remembered. A person who declined in March is not asked in April. `rig doctor
--ask <id>` reverses it. `--yes` accepts every privileged step, and `--no-privileged`
refuses every one. Neither waits for an answer.

## Removal is honest

`rig` records what it applied. `rig remove` undoes that and nothing else. A tool that was
on the machine before `rig` ran is left where it was.

## Documentation

- [docs/design.md](docs/design.md) — the model, the eight kinds, and the limits
- [examples/site.example.yaml](examples/site.example.yaml) — how to describe an organisation
- [examples/hello.product.yaml](examples/hello.product.yaml) — how to add a product

## Limits

| | Supported |
|---|---|
| macOS 13 and later, Apple Silicon and Intel | yes |
| Linux, glibc, x86-64 and arm64 | yes |
| WSL2 | yes, as Linux |
| a container with no root | yes, with `curl` and `unzip` in the image |
| Alpine and musl | not yet |
| Windows, native | not yet |

An honest "not yet" is better than a broken yes.

## License

MIT.
