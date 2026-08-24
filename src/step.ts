/**
 * `step.ts` — the whole engine.
 *
 * A machine has capabilities. A capability can be checked, applied, and removed. Every
 * part of `rig` is that shape: the tool floor, registry access, and a product.
 *
 * ## Why `check` is separate from `apply`
 *
 * `check` never writes. So `rig doctor` is the same code path as the first half of
 * `rig install`, and the two can never disagree about what is true. A diagnostic that
 * quietly repairs is a diagnostic nobody can trust, and it hides the state a person is
 * trying to understand.
 *
 * It is also what makes a second run free. Idempotency is a property of this shape, not a
 * promise that somebody has to test by running the thing twice.
 *
 * ## Why a blocked step is not a failed step
 *
 * A step whose requirement is missing reports `blocked` and names the requirement. It does
 * not run and fail with a symptom. So the first line a reader sees is the real cause, and
 * not the twelve things downstream of it.
 */
import type { Prompter } from "./prompt.ts";
import type { State } from "./state.ts";
import type { Platform } from "./platform.ts";

/** What a `check` found. A verdict carries its own explanation, always. */
export type Verdict =
  /** It is true. Nothing to do. */
  | { state: "ok"; detail: string }
  /** It is not true, and `apply` can make it true. */
  | { state: "missing"; detail: string }
  /** It is not true, and `rig` must not or cannot make it true. `fix` says who can. */
  | { state: "blocked"; detail: string; fix: string[] }
  /** It is deliberately not done. A declined privileged step, or an absent option. */
  | { state: "skipped"; detail: string };

export interface Context {
  platform: Platform;
  state: State;
  ask: Prompter;
  /** Never write. Report what would happen. */
  dryRun: boolean;
}

export interface Step {
  /** Short, stable, and printed. Other steps name it in `requires`. */
  id: string;
  /** Ids that must be `ok` before this one runs. */
  requires: string[];
  /** The group this step prints under. */
  group: string;
  check(ctx: Context): Promise<Verdict>;
  /** Absent means the step reports and never acts. */
  apply?(ctx: Context): Promise<void>;
  /** Absent means there is nothing to undo. */
  remove?(ctx: Context): Promise<void>;
}

/** One step's outcome, for the summary and for `--json`. */
export interface Outcome {
  id: string;
  group: string;
  state: Verdict["state"];
  detail: string;
  fix?: string[];
  /** True when this run changed the machine. Drives what `remove` may undo. */
  applied: boolean;
}

/**
 * Order the steps so every requirement comes before the step that names it.
 *
 * A cycle is a bug in a site file or a product file, not in a person's machine, so it
 * stops with the ids that form it rather than picking an order and hoping.
 */
export function order(steps: Step[]): Step[] {
  const byId = new Map(steps.map((s) => [s.id, s]));
  const sorted: Step[] = [];
  const done = new Set<string>();
  const open = new Set<string>();

  function visit(step: Step, trail: string[]): void {
    if (done.has(step.id)) return;
    if (open.has(step.id)) {
      throw new Error(`These steps require each other: ${[...trail, step.id].join(" → ")}`);
    }
    open.add(step.id);
    for (const id of step.requires) {
      const next = byId.get(id);
      // A requirement that is not present is not an error here. `run` reports it as
      // blocked against the step that named it, where a reader has the context.
      if (next) visit(next, [...trail, step.id]);
    }
    open.delete(step.id);
    done.add(step.id);
    sorted.push(step);
  }

  for (const step of steps) visit(step, []);
  return sorted;
}

export interface RunOptions {
  /** Run every `check` and no `apply`. This is what `doctor` does. */
  checkOnly: boolean;
  /** Called after each step, so a caller can print a line as it happens. */
  onStep?: (outcome: Outcome) => void;
}

/**
 * Check every step, and apply the ones that are missing.
 *
 * A step is applied only when its own `check` says `missing` **and** every id it requires
 * came back `ok`. So a machine that already agrees with the description is left untouched,
 * and a machine that is half-built is finished rather than restarted.
 */
export async function run(steps: Step[], ctx: Context, options: RunOptions): Promise<Outcome[]> {
  const outcomes: Outcome[] = [];
  const verdicts = new Map<string, Verdict["state"]>();

  for (const step of order(steps)) {
    // `skipped` satisfies a requirement. A step that deliberately did nothing — because
    // there was nothing to do — must not block what comes after it, or a machine with no
    // container runtime reports a cascade of failures for work nobody asked for.
    const unmet = step.requires.filter((id) => {
      const verdict = verdicts.get(id);
      return verdict !== "ok" && verdict !== "skipped";
    });
    if (unmet.length > 0) {
      const outcome: Outcome = {
        id: step.id,
        group: step.group,
        state: "blocked",
        detail: `needs ${unmet.join(", ")}`,
        fix: [`Correct ${unmet[0]} first. Every other step is unaffected.`],
        applied: false,
      };
      verdicts.set(step.id, "blocked");
      outcomes.push(outcome);
      options.onStep?.(outcome);
      continue;
    }

    let verdict = await step.check(ctx);
    let applied = false;

    if (verdict.state === "missing" && !options.checkOnly && step.apply && !ctx.dryRun) {
      await step.apply(ctx);
      // Ask again rather than assume. An `apply` that returned without throwing has still
      // not proved anything, and this is the only place that can find out.
      verdict = await step.check(ctx);
      applied = verdict.state === "ok";
      if (applied) ctx.state.recordApplied(step.id);
    }

    const outcome: Outcome = {
      id: step.id,
      group: step.group,
      state: verdict.state,
      detail: verdict.detail,
      ...(verdict.state === "blocked" ? { fix: verdict.fix } : {}),
      applied,
    };
    verdicts.set(step.id, verdict.state);
    outcomes.push(outcome);
    options.onStep?.(outcome);
  }

  return outcomes;
}

/**
 * Undo, in reverse order, and **only what `rig` applied**.
 *
 * The state file is the record. A tool that was on the machine before `rig` ran is left
 * exactly where it was. That difference is what separates an uninstaller from a mess.
 */
export async function undo(steps: Step[], ctx: Context, options: RunOptions): Promise<Outcome[]> {
  const outcomes: Outcome[] = [];

  for (const step of order(steps).reverse()) {
    if (!ctx.state.wasApplied(step.id)) {
      const outcome: Outcome = {
        id: step.id,
        group: step.group,
        state: "skipped",
        detail: "kept. rig did not install this",
        applied: false,
      };
      outcomes.push(outcome);
      options.onStep?.(outcome);
      continue;
    }

    if (!step.remove) {
      const outcome: Outcome = {
        id: step.id,
        group: step.group,
        state: "skipped",
        detail: "kept. this step cannot be undone",
        applied: false,
      };
      outcomes.push(outcome);
      options.onStep?.(outcome);
      continue;
    }

    if (!ctx.dryRun) {
      await step.remove(ctx);
      ctx.state.forgetApplied(step.id);
    }
    const outcome: Outcome = {
      id: step.id,
      group: step.group,
      state: "ok",
      detail: "removed",
      applied: true,
    };
    outcomes.push(outcome);
    options.onStep?.(outcome);
  }

  return outcomes;
}

/** `0` when every step is `ok` or deliberately `skipped`. `1` when anything is wrong. */
export function exitCode(outcomes: Outcome[]): 0 | 1 {
  return outcomes.some((o) => o.state === "missing" || o.state === "blocked") ? 1 : 0;
}
