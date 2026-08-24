/**
 * The engine, proved against fake steps.
 *
 * These tests exist because the three properties `rig` promises — a second run changes
 * nothing, a blocked requirement names itself, and removal touches only what `rig`
 * applied — are properties of this file and of nothing else.
 */
import { describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { exitCode, order, run, undo, type Context, type Step, type Verdict } from "../src/step.ts";
import { State } from "../src/state.ts";
import type { Platform } from "../src/platform.ts";

const platform: Platform = {
  os: "linux",
  arch: "x64",
  release: "test",
  wsl: false,
  container: false,
  interactive: false,
  privileged: false,
  browser: false,
};

function context(): Context {
  const file = join(mkdtempSync(join(tmpdir(), "rig-")), "state.json");
  return {
    platform,
    state: State.open(file),
    ask: {
      consent: async () => "no",
      line: async () => "",
      secret: async () => "",
    },
    dryRun: false,
  };
}

/**
 * A step backed by one boolean, so a test can watch `apply` change what `check` sees.
 * `applyCount` is what proves a second run does nothing.
 */
function fake(id: string, requires: string[] = [], present = false) {
  const box = { present, applyCount: 0, removeCount: 0 };
  const step: Step = {
    id,
    requires,
    group: "test",
    check: async (): Promise<Verdict> =>
      box.present ? { state: "ok", detail: "present" } : { state: "missing", detail: "absent" },
    apply: async () => {
      box.applyCount += 1;
      box.present = true;
    },
    remove: async () => {
      box.removeCount += 1;
      box.present = false;
    },
  };
  return { step, box };
}

describe("order", () => {
  test("puts a requirement before the step that names it", () => {
    const a = fake("a", ["b"]).step;
    const b = fake("b", ["c"]).step;
    const c = fake("c").step;
    expect(order([a, b, c]).map((s) => s.id)).toEqual(["c", "b", "a"]);
  });

  test("names every step in a cycle, instead of picking an order", () => {
    const a = fake("a", ["b"]).step;
    const b = fake("b", ["a"]).step;
    expect(() => order([a, b])).toThrow(/require each other/);
  });

  test("a requirement that does not exist is left to run() to report", () => {
    const a = fake("a", ["absent"]).step;
    expect(order([a]).map((s) => s.id)).toEqual(["a"]);
  });
});

describe("run", () => {
  test("applies a missing step, and reports it as ok", async () => {
    const { step, box } = fake("bun");
    const outcomes = await run([step], context(), { checkOnly: false });
    expect(box.applyCount).toBe(1);
    expect(outcomes[0]?.state).toBe("ok");
    expect(outcomes[0]?.applied).toBe(true);
  });

  test("a second run applies nothing — this is what idempotent means here", async () => {
    const { step, box } = fake("bun");
    const ctx = context();
    await run([step], ctx, { checkOnly: false });
    const second = await run([step], ctx, { checkOnly: false });
    expect(box.applyCount).toBe(1);
    expect(second[0]?.state).toBe("ok");
    expect(second[0]?.applied).toBe(false);
  });

  test("checkOnly never applies, so doctor cannot change the machine", async () => {
    const { step, box } = fake("bun");
    const outcomes = await run([step], context(), { checkOnly: true });
    expect(box.applyCount).toBe(0);
    expect(outcomes[0]?.state).toBe("missing");
  });

  test("dryRun never applies", async () => {
    const { step, box } = fake("bun");
    const ctx = { ...context(), dryRun: true };
    await run([step], ctx, { checkOnly: false });
    expect(box.applyCount).toBe(0);
  });

  test("a step whose requirement failed is blocked, and never runs", async () => {
    const registry = fake("registry");
    registry.step.check = async () => ({ state: "blocked", detail: "no credential", fix: ["log in"] });
    const clients = fake("clients", ["registry"]);

    const outcomes = await run([registry.step, clients.step], context(), { checkOnly: false });
    const blocked = outcomes.find((o) => o.id === "clients");

    expect(clients.box.applyCount).toBe(0);
    expect(blocked?.state).toBe("blocked");
    // The message names the cause, not the symptom.
    expect(blocked?.detail).toContain("registry");
  });

  test("a step that applies but still does not check ok is not recorded as applied", async () => {
    const { step } = fake("stubborn");
    step.apply = async () => {}; // does nothing, so check keeps saying missing
    const ctx = context();
    const outcomes = await run([step], ctx, { checkOnly: false });
    expect(outcomes[0]?.state).toBe("missing");
    expect(ctx.state.wasApplied("stubborn")).toBe(false);
  });
});

describe("undo", () => {
  test("removes only what rig applied, and keeps what was already there", async () => {
    const mine = fake("uv");
    const theirs = fake("bun", [], true); // already on the machine before rig ran
    const ctx = context();

    await run([mine.step, theirs.step], ctx, { checkOnly: false });
    expect(ctx.state.wasApplied("uv")).toBe(true);
    expect(ctx.state.wasApplied("bun")).toBe(false);

    const outcomes = await undo([mine.step, theirs.step], ctx, { checkOnly: false });

    expect(mine.box.removeCount).toBe(1);
    expect(theirs.box.removeCount).toBe(0);
    expect(outcomes.find((o) => o.id === "bun")?.detail).toContain("rig did not install this");
  });

  test("undoes in reverse order, so a requirement outlives what needed it", async () => {
    const seen: string[] = [];
    const base = fake("base");
    const top = fake("top", ["base"]);
    base.step.remove = async () => void seen.push("base");
    top.step.remove = async () => void seen.push("top");

    const ctx = context();
    await run([base.step, top.step], ctx, { checkOnly: false });
    await undo([base.step, top.step], ctx, { checkOnly: false });

    expect(seen).toEqual(["top", "base"]);
  });
});

describe("exitCode", () => {
  test("0 when everything is ok or deliberately skipped", () => {
    expect(
      exitCode([
        { id: "a", group: "g", state: "ok", detail: "", applied: false },
        { id: "b", group: "g", state: "skipped", detail: "", applied: false },
      ]),
    ).toBe(0);
  });

  test("1 when anything is missing or blocked", () => {
    expect(exitCode([{ id: "a", group: "g", state: "missing", detail: "", applied: false }])).toBe(1);
  });
});
