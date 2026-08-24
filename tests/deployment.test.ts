/**
 * Asking a deployment what it needs.
 *
 * Most of these are about failing well. A person meeting a corporate TLS proxy, an
 * address behind a VPN, and a deployment that is simply down all see the same thing from
 * `fetch`, and the fix for each is different. Telling them apart is most of the value.
 */
import { describe, expect, test } from "bun:test";
import { ask, readSetup, Unreachable } from "../src/deployment.ts";

/** A fetch that answers with one body, or throws one error. */
function answers(body: unknown, status = 200): typeof fetch {
  return (async () => new Response(JSON.stringify(body), { status })) as unknown as typeof fetch;
}
function throws(message: string): typeof fetch {
  return (async () => {
    throw new Error(message);
  }) as unknown as typeof fetch;
}

describe("ask", () => {
  test("reads the packages, the name, and the registry", async () => {
    const needs = await ask(
      "https://id.example.com/",
      answers({ name: "dev", clients: ["@example/a-cli", "@example/b-cli"], registry: "https://npm.example.com/" }),
    );
    expect(needs).toEqual({
      name: "dev",
      clients: ["@example/a-cli", "@example/b-cli"],
      registry: "https://npm.example.com/",
    });
  });

  test("a deployment that names nothing is not a failure", async () => {
    // Saying nothing is a real answer: install what you were told to install.
    expect(await ask("https://id.example.com", answers({ clients: [] }))).toEqual({ clients: [] });
  });

  test("a 404 is a wrong address, not a tolerable older deployment", async () => {
    // Tolerating it made every wrong address report a healthy run — the worst outcome
    // available to a setup tool. /v1/services predates this change, so a 404 means the
    // thing at that address is not a deployment.
    const error = await ask("https://wrong.example.com", answers({}, 404)).catch((e) => e);
    expect(error).toBeInstanceOf(Unreachable);
    expect((error as Unreachable).why).toContain("is not a deployment");
  });

  test("entries that are not package names are dropped, not trusted", async () => {
    const needs = await ask("https://id.example.com", answers({ clients: ["@example/a-cli", 42, "", null] }));
    expect(needs.clients).toEqual(["@example/a-cli"]);
  });
});

describe("failing in a way a person can act on", () => {
  test("a value that is not an address is refused before any request", async () => {
    await expect(ask("not a url", throws("should not be called"))).rejects.toThrow(/is not an address/);
  });

  test("a scheme that is not http or https is refused", async () => {
    await expect(ask("file:///etc/passwd", throws("x"))).rejects.toThrow(/not an http or https address/);
  });

  test("a TLS proxy is named as one, not reported as an outage", async () => {
    // On a corporate network this is the single most common first failure, and it reads
    // exactly like the service being down unless something says otherwise.
    const error = await ask("https://id.example.com", throws("unable to verify the first certificate")).catch((e) => e);
    expect(error).toBeInstanceOf(Unreachable);
    expect((error as Unreachable).fix).toContain("inspecting TLS");
  });

  test("a name that does not resolve suggests the VPN", async () => {
    const error = await ask("https://id.example.com", throws("getaddrinfo ENOTFOUND id.example.com")).catch((e) => e);
    expect((error as Unreachable).why).toContain("could not be found");
    expect((error as Unreachable).fix).toContain("VPN");
  });

  test("the wrong service answering is named as that", async () => {
    // Pointing rig at the job manager instead of the identity service is an easy mistake,
    // and "500" alone sends somebody looking in the wrong place.
    const error = await ask("https://jm.example.com", answers({}, 500)).catch((e) => e);
    expect((error as Unreachable).fix).toContain("identity service");
  });

  test("an answer that is not JSON is named as that", async () => {
    const html = (async () => new Response("<html>hello</html>", { status: 200 })) as unknown as typeof fetch;
    const error = await ask("https://id.example.com", html).catch((e) => e);
    expect((error as Unreachable).why).toContain("not with the list rig expected");
  });
});

describe("readSetup", () => {
  test("reads the command a package asks to have run", () => {
    expect(readSetup({ rig: { setup: "tool join $RIG_DEPLOYMENT_URL" } })).toBe("tool join $RIG_DEPLOYMENT_URL");
  });

  test("a package that asks for nothing gets nothing", () => {
    expect(readSetup({})).toBeUndefined();
    expect(readSetup({ rig: {} })).toBeUndefined();
    expect(readSetup(null)).toBeUndefined();
    expect(readSetup("not an object")).toBeUndefined();
  });

  test("a setup that is not a string is ignored", () => {
    expect(readSetup({ rig: { setup: ["rm", "-rf", "/"] } })).toBeUndefined();
  });
});
