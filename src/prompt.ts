/**
 * `prompt.ts` — asking, and knowing when not to ask.
 *
 * Two rules decide everything in this file.
 *
 * **Never wait for input that cannot arrive.** A CI runner, an image build and an agent
 * have no terminal. A tool that blocks on a question there hangs until something kills it,
 * and the log says nothing. Every question here answers itself when there is no terminal.
 *
 * **Never ask twice.** A person who answered `never` to a privileged step is not asked
 * again on any later run. The answer lives in the state file, and one flag reverses it.
 */
import { execFileSync } from "node:child_process";
import { EXIT, note, style } from "./output.ts";
import type { State } from "./state.ts";
import type { Platform } from "./platform.ts";

export type Consent = "yes" | "no" | "never";

export interface PrompterOptions {
  platform: Platform;
  state: State;
  /** Accept every privileged step without asking. */
  assumeYes: boolean;
  /** Refuse every privileged step without asking. */
  refuseAll: boolean;
}

/**
 * The questions `rig` is allowed to ask.
 *
 * There are three, and there will not be a fourth without a good reason. Every question a
 * person did not need to answer is a question we got wrong.
 */
export interface Prompter {
  /** A privileged or optional step. Remembers a `never`. */
  consent(id: string, question: string, because: string[]): Promise<Consent>;
  /** A line of text, such as a user name. */
  line(label: string, fallbackEnv?: string): Promise<string>;
  /** A password. The echo is off, and the value is never logged or stored by rig. */
  secret(label: string, fallbackEnv?: string): Promise<string>;
}

export function prompter(options: PrompterOptions): Prompter {
  const { platform, state } = options;

  return {
    async consent(id, question, because) {
      if (state.declined(id)) {
        return "never";
      }
      if (options.refuseAll) return "no";
      if (options.assumeYes) return "yes";
      if (!platform.interactive) {
        // Silence is not consent. With no terminal, a step that changes the machine in a
        // privileged way must not run on a guess.
        return "no";
      }

      note("");
      for (const line of because) note(`  ${line}`);
      note("");
      const answer = (await readLine(`  ${question}  [y/N/never] `)).trim().toLowerCase();

      if (answer === "never") {
        state.decline(id);
        return "never";
      }
      return answer === "y" || answer === "yes" ? "yes" : "no";
    },

    async line(label, fallbackEnv) {
      const fromEnv = fallbackEnv ? process.env[fallbackEnv] : undefined;
      if (fromEnv) return fromEnv;
      if (!platform.interactive) {
        throw new Missing(label, fallbackEnv);
      }
      return (await readLine(`  ${label}: `)).trim();
    },

    async secret(label, fallbackEnv) {
      const fromEnv = fallbackEnv ? process.env[fallbackEnv] : undefined;
      if (fromEnv) return fromEnv;
      if (!platform.interactive) {
        throw new Missing(label, fallbackEnv);
      }
      return readSecret(`  ${label}: `);
    },
  };
}

/**
 * There is no terminal and no environment variable, so the run stops here.
 *
 * The message names the variable to set, because that is the only thing the caller can do
 * about it. "Input required" would send somebody to read source code.
 */
export class Missing extends Error {
  readonly exitCode = EXIT.impossible;
  constructor(
    readonly label: string,
    readonly variable?: string,
  ) {
    // Two ways out, because the common cause is `curl … | sh` on a real terminal. Running
    // rig directly always has one, and needs no password in an environment variable —
    // where it would also land in shell history.
    const ways = [
      `${label} is needed, and rig could not reach a terminal to ask on.`,
      ``,
      `  Run rig directly, which always has one:`,
      `    rig setup <deployment-url>`,
      ``,
      ...(variable ? [`  Or set ${variable} and re-run.`] : []),
    ];
    super(ways.join("\n"));
    this.name = "Missing";
  }
}


/**
 * Read one line from the terminal.
 *
 * From `/dev/tty`, never from stdin. `curl … | sh` leaves stdin as the pipe carrying the
 * script, so a question read from it gets script text or nothing at all while a person
 * sits at a working terminal. `/dev/tty` is the terminal whatever stdin happens to be —
 * the same thing `ssh`, `sudo` and `git` do, for the same reason.
 *
 * The read is done by `sh` rather than by this process. Reading a tty file descriptor
 * directly depends on how the runtime handles it, and one returned an empty string every
 * time while the person's typed answer sat unread.
 *
 * @param hide  turn the terminal's echo off, for a password.
 */
function readFromTerminal(hide: boolean): string {
  const read = 'IFS= read -r __rig_line < /dev/tty && printf %s "$__rig_line"';
  const script = hide
    ? `stty -echo < /dev/tty 2>/dev/null; ${read}; __rig_status=$?; stty echo < /dev/tty 2>/dev/null; exit $__rig_status`
    : read;
  try {
    return execFileSync("/bin/sh", ["-c", script], {
      encoding: "utf8",
      stdio: ["inherit", "pipe", "inherit"],
    });
  } catch {
    // End of input, or no terminal after all. An empty answer is refused by the caller,
    // which names what to set instead.
    return "";
  } finally {
    // Always, on every path. A terminal left with the echo off shows nothing a person
    // types, in every later command, until they run `stty sane`.
    if (hide) {
      try {
        execFileSync("/bin/sh", ["-c", "stty echo < /dev/tty 2>/dev/null"], { stdio: "ignore" });
      } catch {
        // Nothing to restore.
      }
      process.stderr.write("\n");
    }
  }
}

function readLine(prompt: string): Promise<string> {
  process.stderr.write(prompt);
  return Promise.resolve(readFromTerminal(false));
}

function readSecret(prompt: string): Promise<string> {
  process.stderr.write(prompt);
  return Promise.resolve(readFromTerminal(true));
}

/** Shown under a step that a person declined, so the consequence is never a surprise. */
export function declinedNote(id: string): string[] {
  return [`Reverse this with: ${style.bold(`rig doctor --ask ${id}`)}`];
}
