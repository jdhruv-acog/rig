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
    super(
      variable
        ? `${label} is needed, and there is no terminal to ask on. Set ${variable} instead.`
        : `${label} is needed, and there is no terminal to ask on.`,
    );
    this.name = "Missing";
  }
}

/** Read one line from the terminal. The prompt goes to stderr, with every other prompt. */
function readLine(prompt: string): Promise<string> {
  process.stderr.write(prompt);
  return new Promise((resolve) => {
    const onData = (chunk: Buffer): void => {
      process.stdin.off("data", onData);
      process.stdin.pause();
      resolve(chunk.toString("utf8").replace(/\r?\n$/, ""));
    };
    process.stdin.resume();
    process.stdin.on("data", onData);
  });
}

/**
 * Read a password without showing it.
 *
 * Raw mode stops the terminal from echoing each character. The handler restores the
 * terminal on every path, including the interrupt, because a shell left in raw mode after
 * a cancelled install shows nothing the person types, in any command, until they reset it.
 */
function readSecret(prompt: string): Promise<string> {
  process.stderr.write(prompt);
  const stdin = process.stdin;
  const wasRaw = stdin.isRaw === true;

  return new Promise((resolve, reject) => {
    let value = "";
    const restore = (): void => {
      stdin.off("data", onData);
      if (stdin.setRawMode) stdin.setRawMode(wasRaw);
      stdin.pause();
      process.stderr.write("\n");
    };

    const onData = (chunk: Buffer): void => {
      for (const byte of chunk) {
        if (byte === 0x03) {
          // Ctrl-C. Restore the terminal first, then leave.
          restore();
          reject(new Error("cancelled"));
          return;
        }
        if (byte === 0x0d || byte === 0x0a) {
          restore();
          resolve(value);
          return;
        }
        if (byte === 0x7f || byte === 0x08) {
          value = value.slice(0, -1);
          continue;
        }
        value += String.fromCharCode(byte);
      }
    };

    if (stdin.setRawMode) stdin.setRawMode(true);
    stdin.resume();
    stdin.on("data", onData);
  });
}

/** Shown under a step that a person declined, so the consequence is never a surprise. */
export function declinedNote(id: string): string[] {
  return [`Reverse this with: ${style.bold(`rig doctor --ask ${id}`)}`];
}
