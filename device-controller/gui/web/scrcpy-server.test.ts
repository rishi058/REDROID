import { describe, expect, it } from "vitest";
import { SCRCPY_SERVER_SHA256, SCRCPY_SERVER_VERSION } from "../worker/scrcpy-server.js";

describe("scrcpy server pin", () => {
  it("uses the reviewed official v3.3.3 artifact checksum", () => {
    expect(SCRCPY_SERVER_VERSION).toBe("3.3.3");
    expect(SCRCPY_SERVER_SHA256).toBe("7e70323ba7f259649dd4acce97ac4fefbae8102b2c6d91e2e7be613fd5354be0");
  });
});
