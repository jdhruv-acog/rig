/**
 * `output.ts` — the four marks, and where each stream goes.
 *
 * One vocabulary across every command:
 *
 *   ✓  it is true
 *   –  skipped, and the reason is given
 *   !  it works, and something is worth knowing
 *   ✗  it is wrong, and the fix is on the next line
 *
 * **Progress goes to stderr. Results go to stdout.** So `rig doctor --json | jq` reads
 * only the JSON, and `rig install > log` still shows a person the device code they must
 * type. A tool that mixes the two forces every caller to parse around it.
 *
 * There are no spinners and no redraw. Output has to stay readable in a CI log, in a
 * scrollback buffer, and over a slow connection, and a redraw is unreadable in all three.
 */

/** Written as a code point so this file holds no control byte. */
const ESC = "\u001b[";

const useColor =
  process.stdout.isTTY === true && !process.env["NO_COLOR"] && process.env["TERM"] !== "dumb";

function paint(code: string): (text: string) => string {
  return (text) => (useColor ? `${ESC}${code}m${text}${ESC}0m` : text);
}

export const style = {
  bold: paint("1"),
  dim: paint("2"),
  red: paint("31"),
  green: paint("32"),
  yellow: paint("33"),
  cyan: paint("36"),
};

/** The state of one step, in the order a reader meets them. */
export type Mark = "ok" | "skip" | "note" | "fail";

const MARKS: Record<Mark, string> = {
  ok: style.green("✓"),
  skip: style.dim("–"),
  note: style.yellow("!"),
  fail: style.red("✗"),
};

/** A group of steps. Printed once, before the first step under it. */
export function header(text: string): void {
  process.stderr.write(`\n${style.cyan("==>")} ${style.bold(text)}\n`);
}

/**
 * One step, one line.
 *
 * The id column is a fixed width so a reader's eye tracks down it. A detail that does not
 * fit still prints in full — a truncated reason is worse than a long line.
 */
export function step(mark: Mark, id: string, detail: string): void {
  process.stderr.write(`  ${MARKS[mark]} ${id.padEnd(12)} ${detail}\n`);
}

/**
 * What to run next, under the step that needs it.
 *
 * A refusal that does not carry its own way out makes a person search for one. The fix
 * belongs here, indented below the line that failed, not in a summary at the end.
 */
export function fix(...lines: string[]): void {
  for (const line of lines) process.stderr.write(`      ${style.dim(line)}\n`);
}

/** A blank line, or a sentence that belongs to no step. */
export function note(text = ""): void {
  process.stderr.write(`${text}\n`);
}

/** The result. The only thing on stdout, so a caller can read it alone. */
export function result(value: unknown): void {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
}

/**
 * Exit codes a caller can branch on without reading any text.
 *
 *   0  everything is correct
 *   1  something on this machine is wrong
 *   2  the request cannot be carried out — a name that does not exist, or a bad flag
 */
export const EXIT = { ok: 0, wrong: 1, impossible: 2 } as const;
