import { eq } from "drizzle-orm";
import { database } from "@/lib/db";
import { licenses } from "@/lib/db/schema";
import { formatLicenseKey } from "@/lib/license-key";

export const runtime = "nodejs";

export async function GET(_request: Request, context: RouteContext<"/api/licenses/status/[key]">) {
  const { key: rawKey } = await context.params;
  const key = formatLicenseKey(rawKey);
  if (!key) return Response.json({ status: "invalid" }, { status: 404 });
  const license = await database().query.licenses.findFirst({
    columns: { status: true, amountTotal: true, currency: true },
    where: eq(licenses.id, key),
  });
  if (!license) return Response.json({ status: "invalid" }, { status: 404 });
  return Response.json({
    status: license.status,
    amountTotal: license.status === "active" ? license.amountTotal : undefined,
    currency: license.status === "active" ? license.currency : undefined,
  });
}
