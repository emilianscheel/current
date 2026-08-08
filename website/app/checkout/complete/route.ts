import { eq } from "drizzle-orm";
import { NextRequest, NextResponse } from "next/server";
import { database } from "@/lib/db";
import { licenses } from "@/lib/db/schema";

export const runtime = "nodejs";

export async function GET(request: NextRequest) {
  const paymentIntent = request.nextUrl.searchParams.get("payment_intent");
  if (!paymentIntent) return NextResponse.redirect(new URL("/checkout", request.url));
  const license = await database().query.licenses.findFirst({
    columns: { id: true },
    where: eq(licenses.stripePaymentIntentId, paymentIntent),
  });
  return NextResponse.redirect(new URL(license ? `/${license.id}` : "/checkout", request.url));
}
