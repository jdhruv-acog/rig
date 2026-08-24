/**
 * `state.ts` — the record of what `rig` did.
 *
 * This file is the difference between an uninstaller and a mess.
 *
 * `rig remove` undoes what **`rig` applied**, never what it merely found. A person who had
 * Bun on this machine before `rig` ran keeps their Bun. Without this record, removal has
 * to guess, and guessing wrong deletes somebody's work.
 *
 * It also holds every `never`. A person who declined a privileged step in March must not
 * be asked again in April. An installer that nags is an installer people stop running.
 *
 * It is state, not configuration, so it lives under the XDG state directory. Nothing here
 * is worth editing by hand, and nothing here belongs in a dotfiles repository.
 */
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

/** Raised on every write. An older `rig` refuses a newer file rather than misreading it. */
const SCHEMA = 1;

interface Shape {
  schema: number;
  /** Step ids `rig` applied, and the ISO time it did. Only these may be removed. */
  applied: Record<string, string>;
  /** Step ids the person answered `never` to. Never asked again. */
  declined: Record<string, string>;
}

const EMPTY: Shape = { schema: SCHEMA, applied: {}, declined: {} };

export function stateFile(env: NodeJS.ProcessEnv = process.env): string {
  const override = env["RIG_STATE_FILE"];
  if (override) return override;
  const base = env["XDG_STATE_HOME"] ?? join(homedir(), ".local", "state");
  return join(base, "rig", "state.json");
}

export class State {
  private data: Shape;

  private constructor(
    private readonly file: string,
    data: Shape,
  ) {
    this.data = data;
  }

  /**
   * Read the file, or start empty.
   *
   * A file this `rig` is too old to understand stops the run. A file that is damaged is
   * reported and set aside, because losing the record of what was applied is better than
   * acting on a record that cannot be trusted.
   */
  static open(file: string = stateFile()): State {
    if (!existsSync(file)) return new State(file, structuredClone(EMPTY));

    let parsed: unknown;
    try {
      parsed = JSON.parse(readFileSync(file, "utf8"));
    } catch {
      const aside = `${file}.unreadable`;
      renameSync(file, aside);
      process.stderr.write(
        `rig: ${file} could not be read, so it was moved to ${aside}.\n` +
          `     rig will not undo anything it installed before now.\n`,
      );
      return new State(file, structuredClone(EMPTY));
    }

    const shape = parsed as Partial<Shape>;
    if (typeof shape.schema === "number" && shape.schema > SCHEMA) {
      throw new Error(
        `${file} was written by a newer rig (schema ${shape.schema}, this one reads ${SCHEMA}). ` +
          `Update rig, or move that file aside.`,
      );
    }

    return new State(file, {
      schema: SCHEMA,
      applied: shape.applied ?? {},
      declined: shape.declined ?? {},
    });
  }

  wasApplied(id: string): boolean {
    return id in this.data.applied;
  }

  recordApplied(id: string): void {
    if (this.wasApplied(id)) return;
    this.data.applied[id] = new Date().toISOString();
    this.save();
  }

  forgetApplied(id: string): void {
    if (!this.wasApplied(id)) return;
    delete this.data.applied[id];
    this.save();
  }

  /** True when the person answered `never`. The step is skipped without a question. */
  declined(id: string): boolean {
    return id in this.data.declined;
  }

  decline(id: string): void {
    this.data.declined[id] = new Date().toISOString();
    this.save();
  }

  /** Reverses a `never`, so the next run asks again. This is `rig doctor --ask <id>`. */
  allowAsking(id: string): boolean {
    if (!this.declined(id)) return false;
    delete this.data.declined[id];
    this.save();
    return true;
  }

  get appliedIds(): string[] {
    return Object.keys(this.data.applied);
  }

  /**
   * Write, and never leave a half-written file.
   *
   * A truncated state file after a lost connection or a signal reads as "rig installed
   * nothing", and then removal leaves everything behind. Write beside it, then rename,
   * because rename is the one filesystem operation that is atomic.
   */
  private save(): void {
    mkdirSync(dirname(this.file), { recursive: true });
    const temporary = `${this.file}.new`;
    writeFileSync(temporary, `${JSON.stringify(this.data, null, 2)}\n`, { mode: 0o600 });
    renameSync(temporary, this.file);
  }
}
