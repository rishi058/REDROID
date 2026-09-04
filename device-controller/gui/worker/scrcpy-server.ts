import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";

export const SCRCPY_SERVER_VERSION = "3.3.3";
export const SCRCPY_SERVER_SHA256 = "7e70323ba7f259649dd4acce97ac4fefbae8102b2c6d91e2e7be613fd5354be0";

/** Refuse to start instead of silently streaming with a different server binary. */
export function verifyScrcpyServer(path: string): void {
  if (!existsSync(path)) throw new Error(`scrcpy server artifact is missing: ${path}`);
  const actual = createHash("sha256").update(readFileSync(path)).digest("hex");
  if (actual !== SCRCPY_SERVER_SHA256) {
    throw new Error(`scrcpy server SHA256 mismatch (expected ${SCRCPY_SERVER_SHA256}, got ${actual})`);
  }
}
