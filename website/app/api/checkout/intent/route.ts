import { eq } from "drizzle-orm";
import { database } from "@/lib/db";
import { licenses, users } from "@/lib/db/schema";
import { reserveLicenseKey } from "@/lib/licensing";
import { stripeClient } from "@/lib/stripe";
import { inclusiveTaxLine, PURCHASE_AMOUNT, PURCHASE_CURRENCY } from "@/lib/commerce";

export const runtime = "nodejs";

function taxAddress(address: {
  city: string | null;
  country: string | null;
  line1: string | null;
  line2: string | null;
  postal_code: string | null;
  state: string | null;
}) {
  if (!address.country) return null;
  return {
    city: address.city ?? undefined,
    country: address.country,
    line1: address.line1 ?? undefined,
    line2: address.line2 ?? undefined,
    postal_code: address.postal_code ?? undefined,
    state: address.state ?? undefined,
  };
}

export async function POST(request: Request) {
  try {
    const body = (await request.json()) as { confirmationTokenId?: unknown };
    if (
      typeof body.confirmationTokenId !== "string" ||
      !body.confirmationTokenId.startsWith("ctoken_")
    ) {
      return Response.json({ error: "Invalid payment request." }, { status: 400 });
    }

    const stripe = stripeClient();
    const token = await stripe.confirmationTokens.retrieve(body.confirmationTokenId);
    if (token.payment_intent || !token.payment_method_preview) {
      return Response.json({ error: "This payment request has expired." }, { status: 409 });
    }
    const billing = token.payment_method_preview.billing_details;
    const email = billing.email?.trim().toLowerCase();
    const address = billing.address ? taxAddress(billing.address) : null;
    if (!email || !address) {
      return Response.json(
        { error: "Apple Pay must provide an email and billing address." },
        { status: 400 },
      );
    }

    const db = database();
    let user = await db.query.users.findFirst({ where: eq(users.email, email) });
    if (!user) {
      const customer = await stripe.customers.create({ email });
      const [inserted] = await db
        .insert(users)
        .values({ email, stripeCustomerId: customer.id })
        .onConflictDoNothing({ target: users.email })
        .returning();
      user = inserted ?? (await db.query.users.findFirst({ where: eq(users.email, email) }));
    }
    if (!user) throw new Error("Unable to create customer record");

    const licenseKey = await reserveLicenseKey();
    const tax = await stripe.tax.calculations.create({
      currency: PURCHASE_CURRENCY,
      customer_details: { address, address_source: "billing" },
      line_items: [inclusiveTaxLine(licenseKey)],
    });
    if (!tax.id || tax.amount_total !== PURCHASE_AMOUNT) {
      throw new Error("Stripe Tax returned an unexpected total");
    }

    const intent = await stripe.paymentIntents.create(
      {
        amount: PURCHASE_AMOUNT,
        currency: PURCHASE_CURRENCY,
        customer: user.stripeCustomerId,
        description: `Current lifetime license — ${licenseKey}`,
        metadata: { license_id: licenseKey },
        payment_method_types: ["card"],
        receipt_email: email,
        hooks: { inputs: { tax: { calculation: tax.id } } },
      },
      { idempotencyKey: `current-license-${licenseKey}` },
    );
    if (!intent.client_secret) throw new Error("Stripe did not return a client secret");

    await db
      .update(licenses)
      .set({
        userId: user.id,
        stripePaymentIntentId: intent.id,
        stripeTaxCalculationId: tax.id,
        amountTotal: tax.amount_total,
        amountTax: tax.tax_amount_inclusive,
        updatedAt: new Date(),
      })
      .where(eq(licenses.id, licenseKey));

    return Response.json({ clientSecret: intent.client_secret, licenseKey });
  } catch (error) {
    console.error("checkout intent failed", error);
    return Response.json(
      { error: error instanceof Error ? error.message : "Checkout could not start." },
      { status: 500 },
    );
  }
}
