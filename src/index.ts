#!/usr/bin/env bun
/**
 * `index.ts` — the command surface.
 *
 * Four verbs, and most people use one. `rig setup <url>` is the whole thing: make sure the
 * machine has its runtimes, reach the registry the deployment names, install the tools it
 * names, and hand each one its own setup.
 *
 * Every handler is the same engine walked a different way — `doctor` checks, `setup`
 * checks then applies, `remove` undoes what `rig` applied. So the report and the action can
 * never disagree, and a second run has nothing to do.
 */
import { Command } from "commander";
import { ask, Unreachable, type Needs } from "./deployment.ts";
import { EXIT, fix, header, note, result, step as line, style, type Mark } from "./output.ts";
import { detect, describe } from "./platform.ts";
import { prompter } from "./prompt.ts";
import { State } from "./state.ts";
import { BASE, clientsStep, handoffStep, registryStep } from "./steps.ts";
import { exitCode, run, undo, type Context, type Outcome, type Step } from "./step.ts";
import pkg from "../package.json";

const program = new Command();

program
  .name("rig")
  .description("Make a machine ready — runtimes, registry access, and a deployment's tools")
  .version(pkg.version, "--version")
  .option("--json", "machine-readable output")
  .option("--yes", "accept every step that would ask")
  .option("--no-privileged", "refuse every step that needs a password")
  .addHelpText(
    "after",
    `
Two commands take a machine with nothing to a working one:

  curl -fsSL <install.sh> | sh
  rig setup https://identity.example.com

The deployment says which tools talk to it, so nobody is sent a list of package
names, and a deployment that gains a service reaches every machine on its own.

Examples:
  $ rig setup https://identity.example.com
  $ rig doctor
  $ rig doctor --json
  $ rig base
  $ rig remove`,
  );

/** How each verdict is marked. One vocabulary across every command. */
const MARK: Record<Outcome["state"], Mark> = {
  ok: "ok",
  missing: "note",
  blocked: "fail",
  skipped: "skip",
};

function context(): Context {
  const platform = detect();
  const state = State.open();
  const options = program.opts<{ yes?: boolean; privileged?: boolean }>();
  return {
    platform,
    state,
    ask: prompter({
      platform,
      state,
      assumeYes: options.yes === true,
      // Commander turns `--no-privileged` into privileged: false.
      refuseAll: options.privileged === false,
    }),
    dryRun: false,
  };
}

function isJson(): boolean {
  return program.opts<{ json?: boolean }>().json === true;
}

/** Print one step as it happens, and keep the summary honest. */
function reporter(): { onStep: (o: Outcome) => void } {
  let group = "";
  return {
    onStep(outcome) {
      if (isJson()) return;
      if (outcome.group !== group) {
        group = outcome.group;
        header(group);
      }
      line(MARK[outcome.state], outcome.id, outcome.detail);
      if (outcome.fix) fix(...outcome.fix);
    },
  };
}

function summarise(outcomes: Outcome[], next?: string[]): never {
  if (isJson()) {
    result({ ok: exitCode(outcomes) === 0, steps: outcomes });
    process.exit(exitCode(outcomes));
  }
  const ok = outcomes.filter((o) => o.state === "ok").length;
  const wrong = outcomes.filter((o) => o.state === "missing" || o.state === "blocked").length;
  const skipped = outcomes.filter((o) => o.state === "skipped").length;

  header("summary");
  note(
    `  ${ok} ready` +
      (skipped > 0 ? ` · ${skipped} skipped` : "") +
      (wrong > 0 ? ` · ${style.red(`${wrong} to fix`)}` : ""),
  );
  if (wrong === 0 && next) {
    note("");
    for (const command of next) note(`  ${style.dim(command)}`);
  }
  note("");
  process.exit(exitCode(outcomes));
}

/** The deployment's half of the work, once it has said what it needs. */
function clientSteps(needs: Needs, url: string): Step[] {
  return [registryStep(needs), clientsStep(needs), handoffStep(needs, url)];
}

program
  .command("setup <deployment-url>")
  .description("Make this machine ready for a deployment")
  .addHelpText(
    "after",
    `
Safe to run again. Every step asks "is this true now" before it acts, so a machine
that already agrees is left untouched.

Examples:
  $ rig setup https://identity.example.com
  $ rig setup https://identity.example.com --yes`,
  )
  .action(async (url: string) => {
    const ctx = context();
    if (!isJson()) note(`\n  ${style.bold("rig")} ${pkg.version}  ·  ${describe(ctx.platform)}`);

    const needs = await ask(url);
    if (!isJson() && needs.name) note(`  ${style.dim(`deployment: ${needs.name}`)}`);

    const outcomes = await run([...BASE, ...clientSteps(needs, url)], ctx, {
      checkOnly: false,
      ...reporter(),
    });
    summarise(outcomes, ["Next:  rig doctor " + url]);
  });

program
  .command("base")
  .description("Install the runtimes, and nothing that needs a credential")
  .addHelpText(
    "after",
    `
Public tools only. No organisation, no product, no password. This is the machine a
second product can also assume.

Examples:
  $ rig base`,
  )
  .action(async () => {
    const ctx = context();
    if (!isJson()) note(`\n  ${style.bold("rig")} ${pkg.version}  ·  ${describe(ctx.platform)}`);
    summarise(await run(BASE, ctx, { checkOnly: false, ...reporter() }));
  });

program
  .command("doctor [deployment-url]")
  .description("Check this machine. Changes nothing")
  .addHelpText(
    "after",
    `
Runs every check and no action, so it is always safe. With a deployment's address it
also checks the tools that deployment expects.

Examples:
  $ rig doctor
  $ rig doctor https://identity.example.com
  $ rig doctor --json`,
  )
  .action(async (url?: string) => {
    const ctx = context();
    const steps = url ? [...BASE, ...clientSteps(await ask(url), url)] : BASE;
    summarise(await run(steps, ctx, { checkOnly: true, ...reporter() }));
  });

program
  .command("remove [deployment-url]")
  .description("Undo what rig installed, and nothing else")
  .addHelpText(
    "after",
    `
rig records what it applied. A tool that was on this machine before rig ran is left
exactly where it was.

Examples:
  $ rig remove
  $ rig remove https://identity.example.com`,
  )
  .action(async (url?: string) => {
    const ctx = context();
    const steps = url ? [...BASE, ...clientSteps(await ask(url), url)] : BASE;
    summarise(await undo(steps, ctx, { checkOnly: false, ...reporter() }));
  });

if (process.argv.length <= 2) {
  program.outputHelp();
  process.exit(EXIT.ok);
}

// One handler for every command. Each failure already carries what to do next, so this
// prints it and leaves — a stack trace tells a person nothing they can act on.
program.parseAsync(process.argv).catch((error: unknown) => {
  if (error instanceof Unreachable) {
    note("");
    line("fail", "deployment", error.why);
    fix(error.fix);
    note("");
    process.exit(error.exitCode);
  }
  note("");
  line("fail", "rig", error instanceof Error ? error.message : String(error));
  note("");
  process.exit(EXIT.wrong);
});
