import { activateLicense, deactivateLicense, validateLicense } from "@/lib/licensing";

export const runtime = "nodejs";

export async function POST(
  request: Request,
  context: RouteContext<"/api/licenses/[action]">,
) {
  const { action } = await context.params;
  if (!["activate", "validate", "deactivate"].includes(action)) {
    return Response.json({ ok: false, code: "invalid" }, { status: 404 });
  }
  try {
    const body = (await request.json()) as { licenseKey?: unknown; installationId?: unknown };
    if (typeof body.licenseKey !== "string" || typeof body.installationId !== "string") {
      return Response.json({ ok: false, code: "invalid" }, { status: 400 });
    }
    const result =
      action === "activate"
        ? await activateLicense(body.licenseKey, body.installationId)
        : action === "validate"
          ? await validateLicense(body.licenseKey, body.installationId)
          : await deactivateLicense(body.licenseKey, body.installationId);
    return Response.json(result, { status: result.ok ? 200 : result.code === "limit_reached" ? 409 : 404 });
  } catch (error) {
    console.error(`license ${action} failed`, error);
    return Response.json({ ok: false, code: "unavailable" }, { status: 503 });
  }
}
