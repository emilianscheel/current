import { describe, expect, test } from "bun:test";
import { LICENSE_KEY_PATTERN, formatLicenseKey, generateLicenseKey } from "./license-key";

describe("license keys", () => {
  test("normalizes uppercase alphanumeric groups", () => {
    expect(formatLicenseKey("abc123xyz")).toBe("ABC-123-XYZ");
    expect(formatLicenseKey("abc-123-xyz")).toBe("ABC-123-XYZ");
  });

  test("rejects the wrong number of characters", () => {
    expect(formatLicenseKey("ABC-12-XYZ")).toBeNull();
    expect(formatLicenseKey("ABC-123-XYZ-9")).toBeNull();
  });

  test("generates the database identifier format", () => {
    for (let index = 0; index < 100; index += 1) {
      expect(generateLicenseKey()).toMatch(LICENSE_KEY_PATTERN);
    }
  });
});
