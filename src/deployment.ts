/**
 * `deployment.ts` — asking a deployment what it needs.
 *
 * `rig` is given one address and nothing else. That address answers two questions:
 * which command-line tools talk to it, and where those packages come from. So a person
 * is never sent a list of package names in a message, and a deployment that gains a
 * service reaches every laptop with nothing rewritten.
 *
 * ## What rig will not do
 *
 * It does not execute a command a server sent. The setup step for a tool comes from the
 * tool's own published package, not from an HTTP response — see `readSetup`. A deployment
 * says *what to install*. The package says *what to run*.
 */
import { EXIT } from "./output.ts";

/** What a deployment says it needs. Every field is optional except the address itself. */
export interface Needs {
  /** What the deployment calls itself. Used for messages only. */
  name?: string;
  /** Package names, in the order they are installed. */
  clients: string[];
  /** Where those packages come from, when the deployment has its own registry. */
  registry?: string;
}

/** A refusal a person can act on, rather than a stack trace. */
export class Unreachable extends Error {
  readonly exitCode = EXIT.wrong;
  constructor(
    readonly url: string,
    readonly why: string,
    readonly fix: string,
  ) {
    super(why);
    this.name = "Unreachable";
  }
}

/**
 * Ask a deployment what it needs.
 *
 * The three ways this fails are told apart, because the fix for each is different and a
 * person cannot guess which one they met. A certificate error on a corporate network reads
 * exactly like an outage unless something says so.
 */
export async function ask(url: string, doFetch: typeof fetch = fetch): Promise<Needs> {
  const base = url.trim().replace(/\/+$/, "");

  let parsed: URL;
  try {
    parsed = new URL(base);
  } catch {
    throw new Unreachable(url, `"${url}" is not an address.`, "Give the deployment's URL, starting with https://");
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new Unreachable(url, `"${url}" is not an http or https address.`, "Give the deployment's URL, starting with https://");
  }

  let response: Response;
  try {
    response = await doFetch(`${base}/v1/clients`, { headers: { accept: "application/json" } });
  } catch (cause) {
    const text = String(cause);
    if (/certificate|self-signed|CERT_|unable to verify/i.test(text)) {
      throw new Unreachable(
        base,
        `The certificate for ${parsed.host} was not accepted.`,
        "A proxy on this network is inspecting TLS. Ask whoever runs it for the certificate.",
      );
    }
    if (/ENOTFOUND|EAI_AGAIN|getaddrinfo/i.test(text)) {
      throw new Unreachable(
        base,
        `${parsed.host} could not be found.`,
        "Check the address. If it is an internal one, connect to the VPN first.",
      );
    }
    throw new Unreachable(base, `${parsed.host} did not answer.`, "Check the address, and that you can reach it.");
  }

  if (response.status === 404) {
    // An older deployment has no such route. That is not a failure: it means this
    // deployment does not say, and a person installs what they were told to.
    return { clients: [] };
  }
  if (!response.ok) {
    throw new Unreachable(
      base,
      `${parsed.host} answered ${response.status} when asked what it needs.`,
      "Check the address names the identity service, not one of the services behind it.",
    );
  }

  let body: { name?: string; clients?: unknown; registry?: string };
  try {
    body = (await response.json()) as typeof body;
  } catch {
    throw new Unreachable(
      base,
      `${parsed.host} answered, but not with the list rig expected.`,
      "Check the address names the identity service.",
    );
  }

  const clients = Array.isArray(body.clients)
    ? body.clients.filter((entry): entry is string => typeof entry === "string" && entry.length > 0)
    : [];

  return {
    ...(body.name ? { name: body.name } : {}),
    clients,
    ...(body.registry ? { registry: body.registry } : {}),
  };
}

/**
 * What a package asks to have run after it is installed.
 *
 * Read from the **installed package's own manifest**, never from the deployment's answer.
 * A server that could name a command to run on every laptop that joined it is a much
 * larger thing to trust than one that names packages from a registry you already use.
 *
 * ```json
 * { "rig": { "setup": "mytool join $RIG_DEPLOYMENT_URL" } }
 * ```
 */
export function readSetup(manifest: unknown): string | undefined {
  if (!manifest || typeof manifest !== "object") return undefined;
  const rig = (manifest as Record<string, unknown>)["rig"];
  if (!rig || typeof rig !== "object") return undefined;
  const setup = (rig as Record<string, unknown>)["setup"];
  return typeof setup === "string" && setup.length > 0 ? setup : undefined;
}
