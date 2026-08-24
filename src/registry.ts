/**
 * `registry.ts` — reaching a package registry that asks who you are.
 *
 * `rig` does not know your organisation. It learns the registry host from the deployment,
 * or from the machine's own configuration, and asks for a credential only when one is
 * actually needed. A laptop whose `~/.npmrc` already works never sees a prompt.
 *
 * ## What it writes, and where
 *
 * Two lines in `~/.npmrc`, at 0600: the scope's registry, and that registry's credential.
 * Nothing else. `rig` keeps no credential of its own and has no store of its own.
 *
 * ## What it never does
 *
 * The password is never a command flag, because a flag lands in shell history. It is never
 * written to a log on any channel. It is read, used, and dropped.
 */
import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export function npmrcPath(env: NodeJS.ProcessEnv = process.env): string {
  return env["NPM_CONFIG_USERCONFIG"] ?? join(homedir(), ".npmrc");
}

/** The scope a package name carries: `@example/a-cli` → `@example`. */
export function scopeOf(packageName: string): string | undefined {
  const match = /^(@[^/]+)\//.exec(packageName);
  return match?.[1];
}

/**
 * The registry a scope already resolves to on this machine.
 *
 * Read from `~/.npmrc` rather than assumed, so `rig` reports the host that actually
 * refused rather than one compiled into it. That is what lets the same message serve an
 * organisation's laptop and another's, with different hosts in it and no flag saying which.
 */
export function configuredRegistry(scope: string, env: NodeJS.ProcessEnv = process.env): string | undefined {
  const file = npmrcPath(env);
  if (!existsSync(file)) return undefined;
  const line = readFileSync(file, "utf8")
    .split("\n")
    .find((l) => l.trim().startsWith(`${scope}:registry=`));
  return line?.split("=").slice(1).join("=").trim() || undefined;
}

/** `https://npm.example.com/` → `npm.example.com`. The form npmrc keys credentials by. */
export function hostOf(registry: string): string {
  try {
    const url = new URL(registry);
    return url.host + url.pathname.replace(/\/+$/, "");
  } catch {
    return registry.replace(/^https?:\/\//, "").replace(/\/+$/, "");
  }
}

/** True when this machine already holds a credential for that registry. */
export function hasCredential(registry: string, env: NodeJS.ProcessEnv = process.env): boolean {
  const file = npmrcPath(env);
  if (!existsSync(file)) return false;
  const host = hostOf(registry);
  return readFileSync(file, "utf8")
    .split("\n")
    .some((l) => l.trim().startsWith(`//${host}/:_auth`) || l.trim().startsWith(`//${host}/:_authToken`));
}

/**
 * Point a scope at a registry, and record a credential for it.
 *
 * Every other line in the file survives: this reads it, replaces the two settings it owns,
 * and writes it back. A person's other registries and their other scopes are untouched.
 *
 * The file is written beside itself and renamed, because a truncated `~/.npmrc` after a
 * signal breaks every install on the machine, including the one that would fix it.
 */
export function writeCredential(
  options: { scope: string; registry: string; username: string; password: string },
  env: NodeJS.ProcessEnv = process.env,
): string {
  const file = npmrcPath(env);
  const host = hostOf(options.registry);
  const auth = Buffer.from(`${options.username}:${options.password}`).toString("base64");

  const owned = [`${options.scope}:registry`, `//${host}/:_auth`];
  const kept = (existsSync(file) ? readFileSync(file, "utf8").split("\n") : []).filter((line) => {
    const key = line.split("=")[0]?.trim();
    return !key || !owned.includes(key);
  });

  const body = [
    ...kept.filter((l, i, all) => !(l.trim() === "" && all[i + 1]?.trim() === "")),
    `${options.scope}:registry=${options.registry}`,
    `//${host}/:_auth=${auth}`,
    "",
  ].join("\n");

  const temporary = `${file}.rig`;
  // 0600 from the moment it exists. A default umask leaves a new file world-readable, and
  // this one carries a credential.
  writeFileSync(temporary, body, { mode: 0o600 });
  renameSync(temporary, file);
  return file;
}

export type Reachability = "ok" | "needs-credential" | "unreachable";

/**
 * Can this machine fetch from that registry?
 *
 * Asked before anything is installed and before anybody is prompted, so a laptop that
 * already works is never interrupted, and a laptop that does not is told exactly which
 * host refused.
 */
export async function reach(
  registry: string,
  packageName: string,
  env: NodeJS.ProcessEnv = process.env,
  doFetch: typeof fetch = fetch,
): Promise<Reachability> {
  const file = npmrcPath(env);
  const host = hostOf(registry);
  const line = (existsSync(file) ? readFileSync(file, "utf8").split("\n") : []).find((l) =>
    l.trim().startsWith(`//${host}/:_auth=`),
  );
  const auth = line?.split("=").slice(1).join("=").trim();

  try {
    const response = await doFetch(`${registry.replace(/\/+$/, "")}/${packageName.replace("/", "%2f")}`, {
      headers: auth ? { authorization: `Basic ${auth}` } : {},
    });
    if (response.status === 401 || response.status === 403) return "needs-credential";
    return response.ok || response.status === 404 ? "ok" : "unreachable";
  } catch {
    return "unreachable";
  }
}
