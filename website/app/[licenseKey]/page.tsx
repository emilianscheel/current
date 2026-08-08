import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { eq } from "drizzle-orm";
import { database } from "@/lib/db";
import { licenses } from "@/lib/db/schema";
import { formatLicenseKey } from "@/lib/license-key";
import { LicenseResult } from "./result";

export const dynamic = "force-dynamic";

export const metadata: Metadata = {
  title: "Your Current license",
  robots: { index: false, follow: false, nocache: true },
  referrer: "no-referrer",
};

export default async function LicensePage({ params }: PageProps<"/[licenseKey]">) {
  const { licenseKey: rawKey } = await params;
  const licenseKey = formatLicenseKey(rawKey);
  if (!licenseKey) notFound();
  const license = await database().query.licenses.findFirst({
    columns: { status: true },
    where: eq(licenses.id, licenseKey),
  });
  if (!license) notFound();
  return (
    <main className="license-page">
      <LicenseResult licenseKey={licenseKey} initialStatus={license.status} />
    </main>
  );
}
