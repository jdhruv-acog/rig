/**
 * `platform.ts` — what this machine is, read once.
 *
 * Every later message depends on these answers. A step that asks for a password must know
 * whether anybody can type one. A step that opens a browser must know whether one exists.
 * A download must know the real architecture, not the one an emulator reports.
 *
 * This file only reads. It never installs and never asks.
 */
import { existsSync, readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

export type Os = "macos" | "linux";
export type Arch = "arm64" | "x64";

export interface Platform {
  os: Os;
  arch: Arch;
  /** `24.4.0` on macOS, the kernel release on Linux. Shown, never parsed for logic. */
  release: string;
  /** Windows Subsystem for Linux. The browser lives on the Windows side. */
  wsl: boolean;
  /** A container. There is no shell profile to write and usually no browser. */
  container: boolean;
  /** A person can answer a question. With no terminal, `rig` must never wait. */
  interactive: boolean;
  /** Root already, or a `sudo` that works without asking again. */
  privileged: boolean;
  /** A browser can open here. A device code is still printed either way. */
  browser: boolean;
}

/**
 * The real architecture, not the reported one.
 *
 * On Apple Silicon, a shell running under Rosetta answers `x86_64` to `uname -m`. A tool
 * downloaded for that answer runs emulated: slower, and with nothing to say it is wrong.
 * `sysctl.proc_translated` is the only thing that knows.
 */
function macArch(): Arch {
  const reported = process.arch === "arm64" ? "arm64" : "x64";
  if (reported === "arm64") return "arm64";
  try {
    const translated = execFileSync("/usr/sbin/sysctl", ["-n", "sysctl.proc_translated"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    return translated === "1" ? "arm64" : "x64";
  } catch {
    return "x64";
  }
}

/** True inside Docker, Podman, or a Kubernetes pod. */
function inContainer(): boolean {
  if (existsSync("/.dockerenv")) return true;
  if (process.env["container"]) return true;
  try {
    return /docker|containerd|kubepods|podman/.test(readFileSync("/proc/1/cgroup", "utf8"));
  } catch {
    return false;
  }
}

function isWsl(): boolean {
  if (process.env["WSL_DISTRO_NAME"]) return true;
  try {
    return readFileSync("/proc/version", "utf8").toLowerCase().includes("microsoft");
  } catch {
    return false;
  }
}

/**
 * Can this process gain root without a question?
 *
 * `sudo -n true` asks nothing and answers honestly. Testing for the `sudo` binary alone
 * says only that the command exists, which is why a step that trusted that used to fail
 * much later, at a password prompt nobody could answer.
 */
function isPrivileged(): boolean {
  if (typeof process.getuid === "function" && process.getuid() === 0) return true;
  try {
    execFileSync("sudo", ["-n", "true"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

export function detect(env: NodeJS.ProcessEnv = process.env): Platform {
  const os: Os = process.platform === "darwin" ? "macos" : "linux";
  const container = os === "linux" && inContainer();
  const wsl = os === "linux" && isWsl();

  return {
    os,
    arch: os === "macos" ? macArch() : process.arch === "arm64" ? "arm64" : "x64",
    release: process.platform === "darwin" ? macRelease() : kernelRelease(),
    wsl,
    container,
    // Both streams, because a question needs somewhere to print and somewhere to read.
    interactive: process.stdin.isTTY === true && process.stderr.isTTY === true,
    privileged: isPrivileged(),
    // WSL reaches the Windows browser through interop. A container reaches none.
    browser: os === "macos" || wsl || (!container && Boolean(env["DISPLAY"] ?? env["WAYLAND_DISPLAY"])),
  };
}

function macRelease(): string {
  try {
    return execFileSync("/usr/bin/sw_vers", ["-productVersion"], { encoding: "utf8" }).trim();
  } catch {
    return "unknown";
  }
}

function kernelRelease(): string {
  try {
    return execFileSync("uname", ["-r"], { encoding: "utf8" }).trim();
  } catch {
    return "unknown";
  }
}

/** One line for the top of every run. A reader checks it before believing anything else. */
export function describe(p: Platform): string {
  const parts = [
    p.os === "macos" ? `macOS ${p.release}` : `Linux ${p.release}`,
    p.arch,
    p.wsl ? "WSL" : "",
    p.container ? "container" : "",
    p.privileged ? "root available" : "no root",
    p.interactive ? "" : "no terminal",
  ];
  return parts.filter(Boolean).join(" · ");
}
