import "server-only";

import { createHash } from "node:crypto";
import { and, count, eq, isNull, sql } from "drizzle-orm";
import { activations, licenses } from "./db/schema";
import { database } from "./db";
import { formatLicenseKey, generateLicenseKey } from "./license-key";

export const MAX_ACTIVATIONS = 3;

export function hashInstallationId(installationId: string): string | null {
  const normalized = installationId.trim();
  if (!/^[A-Fa-f0-9-]{16,64}$/.test(normalized)) return null;
  return createHash("sha256").update(normalized).digest("hex");
}

export async function reserveLicenseKey(): Promise<string> {
  const db = database();
  for (let attempt = 0; attempt < 12; attempt += 1) {
    const id = generateLicenseKey();
    const inserted = await db
      .insert(licenses)
      .values({ id })
      .onConflictDoNothing()
      .returning({ id: licenses.id });
    if (inserted[0]) return id;
  }
  throw new Error("Unable to allocate a license key");
}

export async function activateLicense(rawKey: string, installationId: string) {
  const key = formatLicenseKey(rawKey);
  const deviceHash = hashInstallationId(installationId);
  if (!key || !deviceHash) return { ok: false as const, code: "invalid" as const };

  const db = database();
  return db.transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtext(${key}))`);
    const license = await tx.query.licenses.findFirst({
      where: and(eq(licenses.id, key), eq(licenses.status, "active")),
    });
    if (!license) return { ok: false as const, code: "invalid" as const };

    const existing = await tx.query.activations.findFirst({
      where: and(
        eq(activations.licenseId, key),
        eq(activations.deviceHash, deviceHash),
      ),
    });
    if (existing) {
      if (existing.deactivatedAt === null) {
        await tx
          .update(activations)
          .set({ lastValidatedAt: new Date() })
          .where(eq(activations.id, existing.id));
        return { ok: true as const, licenseKey: key, maxActivations: MAX_ACTIVATIONS };
      }
      const [active] = await tx
        .select({ value: count() })
        .from(activations)
        .where(and(eq(activations.licenseId, key), isNull(activations.deactivatedAt)));
      if (active.value >= MAX_ACTIVATIONS) {
        return { ok: false as const, code: "limit_reached" as const };
      }
      await tx
        .update(activations)
        .set({ deactivatedAt: null, lastValidatedAt: new Date() })
        .where(eq(activations.id, existing.id));
      return { ok: true as const, licenseKey: key, maxActivations: MAX_ACTIVATIONS };
    }

    const [active] = await tx
      .select({ value: count() })
      .from(activations)
      .where(and(eq(activations.licenseId, key), isNull(activations.deactivatedAt)));
    if (active.value >= MAX_ACTIVATIONS) {
      return { ok: false as const, code: "limit_reached" as const };
    }
    await tx.insert(activations).values({ licenseId: key, deviceHash });
    return { ok: true as const, licenseKey: key, maxActivations: MAX_ACTIVATIONS };
  });
}

export async function validateLicense(rawKey: string, installationId: string) {
  const key = formatLicenseKey(rawKey);
  const deviceHash = hashInstallationId(installationId);
  if (!key || !deviceHash) return { ok: false as const, code: "invalid" as const };
  const db = database();
  const activation = await db
    .select({ id: activations.id })
    .from(activations)
    .innerJoin(licenses, eq(licenses.id, activations.licenseId))
    .where(
      and(
        eq(licenses.id, key),
        eq(licenses.status, "active"),
        eq(activations.deviceHash, deviceHash),
        isNull(activations.deactivatedAt),
      ),
    )
    .limit(1);
  if (!activation[0]) return { ok: false as const, code: "invalid" as const };
  await db
    .update(activations)
    .set({ lastValidatedAt: new Date() })
    .where(eq(activations.id, activation[0].id));
  return { ok: true as const, licenseKey: key, maxActivations: MAX_ACTIVATIONS };
}

export async function deactivateLicense(rawKey: string, installationId: string) {
  const key = formatLicenseKey(rawKey);
  const deviceHash = hashInstallationId(installationId);
  if (!key || !deviceHash) return { ok: false as const, code: "invalid" as const };
  const db = database();
  const changed = await db
    .update(activations)
    .set({ deactivatedAt: new Date(), lastValidatedAt: new Date() })
    .where(
      and(
        eq(activations.licenseId, key),
        eq(activations.deviceHash, deviceHash),
        isNull(activations.deactivatedAt),
      ),
    )
    .returning({ id: activations.id });
  return changed[0]
    ? { ok: true as const }
    : { ok: false as const, code: "invalid" as const };
}
