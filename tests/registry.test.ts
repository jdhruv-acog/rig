/**
 * Reaching a registry that asks who you are.
 *
 * The rule these tests protect: `rig` names the host that actually refused, read from the
 * machine's own configuration, never one compiled into it. That is what lets one message
 * serve two organisations with no flag saying which.
 */
import { describe, expect, test, beforeEach } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  configuredRegistry,
  hasCredential,
  hostOf,
  reach,
  scopeOf,
  writeCredential,
} from "../src/registry.ts";

let file: string;
let env: NodeJS.ProcessEnv;

beforeEach(() => {
  file = join(mkdtempSync(join(tmpdir(), "rig-npmrc-")), ".npmrc");
  env = { NPM_CONFIG_USERCONFIG: file };
});

describe("reading what the machine already has", () => {
  test("a scope comes from the package name", () => {
    expect(scopeOf("@example/a-cli")).toBe("@example");
    expect(scopeOf("plain-package")).toBeUndefined();
  });

  test("the registry for a scope is read, never assumed", () => {
    writeFileSync(file, "@example:registry=https://npm.example.com/\n");
    expect(configuredRegistry("@example", env)).toBe("https://npm.example.com/");
    expect(configuredRegistry("@other", env)).toBeUndefined();
  });

  test("no file at all is not an error", () => {
    expect(configuredRegistry("@example", env)).toBeUndefined();
    expect(hasCredential("https://npm.example.com/", env)).toBe(false);
  });

  test("a host is the form npmrc keys credentials by", () => {
    expect(hostOf("https://npm.example.com/")).toBe("npm.example.com");
    expect(hostOf("https://registry.example.com:4443/repo/")).toBe("registry.example.com:4443/repo");
  });

  test("both credential spellings count", () => {
    writeFileSync(file, "//npm.example.com/:_authToken=abc\n");
    expect(hasCredential("https://npm.example.com/", env)).toBe(true);
  });
});

describe("writing a credential", () => {
  test("writes the scope and the credential, and nothing else", () => {
    writeCredential(
      { scope: "@example", registry: "https://npm.example.com/", username: "me", password: "secret" },
      env,
    );
    const text = readFileSync(file, "utf8");
    expect(text).toContain("@example:registry=https://npm.example.com/");
    expect(text).toContain(`//npm.example.com/:_auth=${Buffer.from("me:secret").toString("base64")}`);
  });

  test("the file is 0600 from the moment it exists", () => {
    // A default umask leaves a new file world-readable, and this one carries a credential.
    writeCredential({ scope: "@example", registry: "https://npm.example.com/", username: "m", password: "p" }, env);
    expect(statSync(file).mode & 0o777).toBe(0o600);
  });

  test("everything else in the file survives", () => {
    writeFileSync(file, "@other:registry=https://other.example.com/\nsave-exact=true\n");
    writeCredential({ scope: "@example", registry: "https://npm.example.com/", username: "m", password: "p" }, env);
    const text = readFileSync(file, "utf8");
    expect(text).toContain("@other:registry=https://other.example.com/");
    expect(text).toContain("save-exact=true");
  });

  test("writing twice replaces, rather than piling up", () => {
    const opts = { scope: "@example", registry: "https://npm.example.com/", username: "m", password: "p" };
    writeCredential(opts, env);
    writeCredential({ ...opts, password: "new" }, env);
    const lines = readFileSync(file, "utf8").split("\n").filter((l) => l.includes("_auth="));
    // A previous credential left behind is a credential still on disk after a rotation.
    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain(Buffer.from("m:new").toString("base64"));
  });
});

describe("reach", () => {
  const ok = (status: number) => (async () => new Response("{}", { status })) as unknown as typeof fetch;

  test("200 means this machine can install from it", async () => {
    expect(await reach("https://npm.example.com/", "@example/a-cli", env, ok(200))).toBe("ok");
  });

  test("404 also means it can — the registry answered, the package is just not there", async () => {
    expect(await reach("https://npm.example.com/", "@example/a-cli", env, ok(404))).toBe("ok");
  });

  test("401 and 403 mean a credential is needed, not that anything is broken", async () => {
    expect(await reach("https://npm.example.com/", "@example/a-cli", env, ok(401))).toBe("needs-credential");
    expect(await reach("https://npm.example.com/", "@example/a-cli", env, ok(403))).toBe("needs-credential");
  });

  test("a network failure is unreachable, which has a different fix", async () => {
    const dead = (async () => {
      throw new Error("ENOTFOUND");
    }) as unknown as typeof fetch;
    expect(await reach("https://npm.example.com/", "@example/a-cli", env, dead)).toBe("unreachable");
  });

  test("an existing credential is presented, so a working laptop is never prompted", async () => {
    writeFileSync(file, `//npm.example.com/:_auth=${Buffer.from("m:p").toString("base64")}\n`);
    chmodSync(file, 0o600);
    let sent: string | undefined;
    const spy = (async (_u: string, init?: RequestInit) => {
      sent = (init?.headers as Record<string, string>)?.["authorization"];
      return new Response("{}", { status: 200 });
    }) as unknown as typeof fetch;
    await reach("https://npm.example.com/", "@example/a-cli", env, spy);
    expect(sent).toBe(`Basic ${Buffer.from("m:p").toString("base64")}`);
  });
});
