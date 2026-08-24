/**
 * `steps.ts` — what `rig` actually checks and does.
 *
 * Two groups, and they are deliberately separate.
 *
 * **base** is public. It installs runtimes into user directories, needs no credential and
 * no administrator password, and knows nothing about any organisation. A machine that only
 * ever runs this is still a useful machine.
 *
 * **clients** is the deployment's half. It asks the deployment which tools talk to it,
 * makes sure the registry those come from is reachable, installs them, and hands over.
 *
 * Every step answers the same four questions, so `doctor`, `setup` and `remove` are the
 * same code walked three ways.
 */
import { execFileSync, spawnSync } from "node:child_process";
import { accessSync, constants, existsSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { Needs } from "./deployment.ts";
import { readSetup } from "./deployment.ts";
import { configuredRegistry, hasCredential, reach, scopeOf, writeCredential } from "./registry.ts";
import type { Step, Verdict } from "./step.ts";

/** Where user-local tools go. One directory, on PATH, owned by the person. */
export const BIN = join(homedir(), ".local", "bin");

/**
 * Is this command on PATH?
 *
 * PATH is read directly rather than asked of a shell. `command -v` through a subprocess
 * depends on which shell answers and how the runtime spawns it, and it reported "not
 * installed" for a binary that was sitting in the directory rig had just written it to.
 * Reading the directories is unambiguous, and it costs no process.
 */
function has(command: string): boolean {
  return pathTo(command) !== undefined;
}

function pathTo(command: string): string | undefined {
  for (const dir of (process.env["PATH"] ?? "").split(":")) {
    if (!dir) continue;
    const candidate = join(dir, command);
    try {
      if (statSync(candidate).isFile()) {
        accessSync(candidate, constants.X_OK);
        return candidate;
      }
    } catch {
      // Not here, or not executable. Try the next directory.
    }
  }
  return undefined;
}

function version(command: string, args: string[] = ["--version"]): string {
  const binary = pathTo(command);
  if (!binary) return "";
  try {
    return execFileSync(binary, args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] })
      .trim()
      .split("\n")[0]!;
  } catch {
    return "";
  }
}

/** Run a command, showing nothing unless it fails. */
function run(command: string, args: string[], env: NodeJS.ProcessEnv = process.env): void {
  const result = spawnSync(command, args, { stdio: ["ignore", "ignore", "pipe"], env });
  if (result.status !== 0) {
    const detail = result.stderr?.toString().trim().split("\n").slice(-3).join("\n") ?? "";
    throw new Error(`${command} ${args.join(" ")} failed.\n${detail}`);
  }
}

// ── base ─────────────────────────────────────────────────────────────────────

/**
 * Bun, which `rig` itself runs on.
 *
 * It is always already here: `install.sh` put it there before `rig` could run at all. So
 * this reports and never installs — a step that claimed to install its own runtime would
 * be describing something that cannot happen.
 */
const bun: Step = {
  id: "bun",
  requires: [],
  group: "base",
  check: async (): Promise<Verdict> =>
    has("bun")
      ? { state: "ok", detail: version("bun") }
      : {
          state: "blocked",
          detail: "not on PATH",
          fix: ["Open a new terminal, or: export PATH=\"$HOME/.bun/bin:$PATH\""],
        },
};

/** `~/.local/bin` on PATH, which is where everything else lands. */
/**
 * `~/.local/bin` on PATH, which is where everything else lands.
 *
 * This reports and never acts. `install.sh` owns the one managed block in the shell file,
 * and a second writer here is how PATH order becomes whichever tool ran last. It cannot
 * change the shell that is running it either — so it says the line to run, which is the
 * only thing that actually helps.
 */
const path: Step = {
  id: "path",
  requires: [],
  group: "base",
  check: async (): Promise<Verdict> =>
    (process.env["PATH"] ?? "").split(":").includes(BIN)
      ? { state: "ok", detail: BIN }
      : {
          state: "blocked",
          detail: `${BIN} is not on PATH`,
          fix: ["Open a new terminal, or run:", `export PATH="${BIN}:$PATH"`],
        },
};

/** A tool `mise` manages, named and pinned by the caller. */
function tool(id: string, versionSpec: string): Step {
  return {
    id,
    requires: ["mise"],
    group: "base",
    check: async (): Promise<Verdict> => {
      const listed = version("mise", ["ls", "--installed", id]);
      return listed ? { state: "ok", detail: listed.split(/\s+/).slice(0, 2).join(" ") } : { state: "missing", detail: "not installed" };
    },
    apply: async () => run("mise", ["use", "--global", `${id}@${versionSpec}`]),
    remove: async () => run("mise", ["uninstall", id]),
  };
}

/**
 * `mise` manages the runtimes.
 *
 * Installing and pinning a language runtime on three operating systems, in a user
 * directory, with no administrator password, is a solved problem. Writing a fourth
 * solution here would be four hundred lines that go stale.
 */
const mise: Step = {
  id: "mise",
  requires: [],
  group: "base",
  check: async (): Promise<Verdict> =>
    has("mise") ? { state: "ok", detail: version("mise") } : { state: "missing", detail: "not installed" },
  apply: async () => {
    run("/bin/sh", ["-c", `curl -fsSL https://mise.run | MISE_INSTALL_PATH=${BIN}/mise sh`]);
  },
  remove: async () => run("/bin/sh", ["-c", `rm -f ${BIN}/mise`]),
};

/**
 * A container runtime. **Advisory, always.**
 *
 * Container work needs one and everything else does not. A machine without one is still a
 * working machine, so this reports and never blocks — and never asks for a password.
 */
const container: Step = {
  id: "container",
  requires: [],
  group: "base",
  check: async (): Promise<Verdict> => {
    if (!has("docker") && !has("podman")) {
      return { state: "skipped", detail: "none. Only container work needs one" };
    }
    const engine = has("docker") ? "docker" : "podman";
    try {
      execFileSync(engine, ["info"], { stdio: "ignore" });
      return { state: "ok", detail: `${engine}, running` };
    } catch {
      return { state: "skipped", detail: `${engine} is installed but not running` };
    }
  },
};

export const BASE: Step[] = [bun, path, mise, tool("uv", "latest"), tool("python", "3.14"), container];

// ── the deployment's clients ─────────────────────────────────────────────────

/** Which package supplies which command, for reporting what is missing. */
function commandsOf(packageName: string): string[] {
  const manifest = manifestOf(packageName);
  const bin = manifest && typeof manifest === "object" ? (manifest as Record<string, unknown>)["bin"] : undefined;
  if (typeof bin === "string") return [packageName.split("/").pop()!];
  if (bin && typeof bin === "object") return Object.keys(bin as Record<string, string>);
  return [];
}

/**
 * Where bun keeps global packages — asked, never assumed.
 *
 * `~/.bun/install/global` is right on some versions and not on others, and a hardcoded
 * path made `bun add -g` succeed while the check that followed reported nothing installed.
 * `bun pm ls -g` prints the directory on its first line, whatever version is running.
 */
/** Where bun puts the commands it installs globally. Asked, never assumed. */
function bunBin(): string {
  try {
    return execFileSync("bun", ["pm", "bin", "-g"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return join(homedir(), ".bun", "bin");
  }
}

function globalRoot(): string {
  try {
    const first = execFileSync("bun", ["pm", "ls", "-g"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).split("\n")[0];
    const dir = first?.replace(/\s+node_modules.*$/, "").trim();
    if (dir && existsSync(join(dir, "node_modules"))) return join(dir, "node_modules");
  } catch {
    // bun is absent or too old to answer. Fall through to the usual place.
  }
  return join(homedir(), ".bun", "install", "global", "node_modules");
}

/** The installed package's own manifest, or undefined when it is not installed. */
function manifestOf(packageName: string): unknown {
  const file = join(globalRoot(), packageName, "package.json");
  if (!existsSync(file)) return undefined;
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return undefined;
  }
}

/**
 * The registry the deployment's packages come from must answer.
 *
 * Checked before anything is installed, so a person is told which host refused rather than
 * meeting a `401` in the middle of an install, and a laptop that already works is never
 * interrupted for a credential it does not need.
 */
export function registryStep(needs: Needs): Step {
  const first = needs.clients[0];
  const scope = first ? scopeOf(first) : undefined;

  return {
    id: "registry",
    requires: [],
    group: "clients",
    check: async (ctx): Promise<Verdict> => {
      if (!first || !scope) return { state: "skipped", detail: "this deployment names no packages" };

      const registry = needs.registry ?? configuredRegistry(scope) ?? "https://registry.npmjs.org/";
      const host = new URL(registry).host;
      const state = await reach(registry, first);

      if (state === "ok") return { state: "ok", detail: `${host}, reachable` };
      if (state === "not-served") {
        // The registry answered and does not have this package. Almost always: the scope
        // resolves to the public registry because nothing on this machine says otherwise,
        // and the deployment did not name its own.
        return {
          state: "blocked",
          detail: `${host} does not serve ${first}`,
          fix: [
            `${scope} resolves to ${host} on this machine, and the package is not there.`,
            `Ask whoever runs the deployment to set ATK_ID_CLIENT_REGISTRY,`,
            `or point the scope at the right registry:`,
            `  npm config set ${scope}:registry https://<your-registry>/`,
          ],
        };
      }
      if (state === "unreachable") {
        return {
          state: "blocked",
          detail: `${host} did not answer`,
          fix: ["Check your network. If that host is internal, connect to the VPN first."],
        };
      }
      return hasCredential(registry) && !ctx.platform.interactive
        ? { state: "blocked", detail: `${host} refused the credential on this machine`, fix: [`Check the credential for ${host}.`] }
        : { state: "missing", detail: `${host} needs a credential` };
    },
    apply: async (ctx) => {
      if (!first || !scope) return;
      const registry = needs.registry ?? configuredRegistry(scope) ?? "https://registry.npmjs.org/";
      const host = new URL(registry).host;

      const username = await ctx.ask.line(`Username for ${host}`, "RIG_REGISTRY_USERNAME");
      const password = await ctx.ask.secret(`Password for ${host}`, "RIG_REGISTRY_PASSWORD");
      writeCredential({ scope, registry, username, password });
    },
  };
}

/**
 * The tools this deployment says talk to it.
 *
 * The list comes from the deployment, so a deployment that gains a service reaches every
 * laptop with nothing rewritten and nobody re-reading an onboarding message.
 */
export function clientsStep(needs: Needs): Step {
  return {
    id: "clients",
    requires: ["bun", "registry"],
    group: "clients",
    check: async (): Promise<Verdict> => {
      if (needs.clients.length === 0) return { state: "skipped", detail: "this deployment names no packages" };
      const missing = needs.clients.filter((name) => manifestOf(name) === undefined);
      if (missing.length > 0) return { state: "missing", detail: `${missing.length} of ${needs.clients.length} not installed` };

      const commands = needs.clients.flatMap(commandsOf);
      // Installed, but this shell was started before they existed. Saying "ok" here sends
      // a person straight to `command not found`, which reads like the install failed.
      const unreachable = commands.filter((c) => !has(c));
      if (unreachable.length > 0) {
        return {
          state: "note",
          detail: `${commands.join(" · ")} — installed, not yet on this shell's PATH`,
          fix: [`Open a new terminal, or run:`, `export PATH="${bunBin()}:$PATH"`],
        };
      }
      return { state: "ok", detail: commands.join(" · ") };
    },
    apply: async () => run("bun", ["add", "-g", ...needs.clients]),
    remove: async () => run("bun", ["remove", "-g", ...needs.clients]),
  };
}

/**
 * Hand over to each tool's own setup.
 *
 * The command comes from the **installed package's manifest**, never from the deployment's
 * answer. A server that could name a command to run on every laptop that joined it is a
 * far larger thing to trust than one that names packages from a registry already in use.
 */
export function handoffStep(needs: Needs, url: string): Step {
  // One id per deployment, so setting up a second one runs its setup rather than
  // reporting the first one as already done.
  const id = "configure";
  return {
    id,
    requires: ["clients"],
    group: "clients",
    check: async (ctx): Promise<Verdict> => {
      const asked = needs.clients.map(manifestOf).map(readSetup).filter(Boolean);
      if (asked.length === 0) return { state: "skipped", detail: "no tool asked for a setup step" };

      // Only the tool knows whether it is configured, and asking it would mean running
      // something on every check — which `doctor` must never do. So rig records that it
      // ran the handoff, and a person who wants it again removes and sets up.
      return ctx.state.wasApplied(`${id}:${url}`)
        ? { state: "ok", detail: `${asked.length} tool${asked.length === 1 ? "" : "s"} configured` }
        : { state: "missing", detail: `${asked.length} to run` };
    },
    apply: async (ctx) => {
      for (const name of needs.clients) {
        const setup = readSetup(manifestOf(name));
        if (!setup) continue;
        // Inherited output, so the tool's own instructions reach the person. rig hands
        // over here and stops speaking for it.
        const result = spawnSync("/bin/sh", ["-c", setup], {
          stdio: "inherit",
          env: { ...process.env, RIG_DEPLOYMENT_URL: url },
        });
        if (result.status !== 0) throw new Error(`${name} could not configure itself: ${setup}`);
      }
      ctx.state.recordApplied(`${id}:${url}`);
    },
  };
}
