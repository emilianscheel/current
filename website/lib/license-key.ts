import { randomInt } from "node:crypto";

export const LICENSE_KEY_PATTERN = /^[A-Z0-9]{3}(?:-[A-Z0-9]{3}){2}$/;
const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

export function formatLicenseKey(value: string): string | null {
  const compact = value.toUpperCase().replace(/[^A-Z0-9]/g, "");
  if (compact.length !== 9) return null;
  const formatted = compact.match(/.{3}/g)?.join("-") ?? "";
  return LICENSE_KEY_PATTERN.test(formatted) ? formatted : null;
}

export function generateLicenseKey(): string {
  let compact = "";
  for (let index = 0; index < 9; index += 1) {
    compact += ALPHABET[randomInt(ALPHABET.length)];
  }
  return formatLicenseKey(compact)!;
}
