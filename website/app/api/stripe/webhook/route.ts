import Stripe from "stripe";
import { eq } from "drizzle-orm";
import { database } from "@/lib/db";
import { activations, licenses, webhookEvents } from "@/lib/db/schema";
import { stripeClient } from "@/lib/stripe";
import { shouldRevokeDispute, shouldRevokeRefund } from "@/lib/commerce";

export const runtime = "nodejs";

type WebhookMutation =
  | { kind: "paid" | "failed"; paymentIntentId: string }
  | { kind: "revoke"; paymentIntentId: string; status: "refunded" | "disputed" }
  | { kind: "none" };

async function mutationFor(event: Stripe.Event): Promise<WebhookMutation> {
  switch (event.type) {
    case "payment_intent.succeeded": {
      return { kind: "paid", paymentIntentId: event.data.object.id };
    }
    case "payment_intent.payment_failed": {
      return { kind: "failed", paymentIntentId: event.data.object.id };
    }
    case "charge.refunded": {
      const charge = event.data.object;
      const paymentIntentId =
        typeof charge.payment_intent === "string" ? charge.payment_intent : null;
      if (paymentIntentId && shouldRevokeRefund(charge.amount, charge.amount_refunded)) {
        return { kind: "revoke", paymentIntentId, status: "refunded" };
      }
      return { kind: "none" };
    }
    case "charge.dispute.closed": {
      const dispute = event.data.object;
      if (!shouldRevokeDispute(dispute.status)) return { kind: "none" };
      const charge =
        typeof dispute.charge === "string"
          ? await stripeClient().charges.retrieve(dispute.charge)
          : dispute.charge;
      const paymentIntentId =
        typeof charge.payment_intent === "string" ? charge.payment_intent : null;
      return paymentIntentId
        ? { kind: "revoke", paymentIntentId, status: "disputed" }
        : { kind: "none" };
    }
    default:
      return { kind: "none" };
  }
}

async function handleEvent(event: Stripe.Event) {
  const mutation = await mutationFor(event);
  const db = database();
  await db.transaction(async (tx) => {
    const seen = await tx
      .insert(webhookEvents)
      .values({ id: event.id, type: event.type })
      .onConflictDoNothing()
      .returning({ id: webhookEvents.id });
    if (!seen[0] || mutation.kind === "none") return;

    if (mutation.kind === "paid" || mutation.kind === "failed") {
      await tx
        .update(licenses)
        .set(mutation.kind === "paid"
          ? { status: "active", purchasedAt: new Date(), updatedAt: new Date() }
          : { status: "failed", updatedAt: new Date() })
        .where(eq(licenses.stripePaymentIntentId, mutation.paymentIntentId));
      return;
    }

    if (mutation.kind !== "revoke") return;
    const [license] = await tx
      .update(licenses)
      .set({ status: mutation.status, updatedAt: new Date() })
      .where(eq(licenses.stripePaymentIntentId, mutation.paymentIntentId))
      .returning({ id: licenses.id });
    if (license) {
      await tx
        .update(activations)
        .set({ deactivatedAt: new Date() })
        .where(eq(activations.licenseId, license.id));
    }
  });
}

export async function POST(request: Request) {
  const signature = request.headers.get("stripe-signature");
  const secret = process.env.STRIPE_WEBHOOK_SECRET;
  if (!signature || !secret) return new Response("Webhook is not configured", { status: 400 });
  try {
    const payload = await request.text();
    const event = stripeClient().webhooks.constructEvent(payload, signature, secret);
    await handleEvent(event);
    return Response.json({ received: true });
  } catch (error) {
    console.error("stripe webhook failed", error);
    return new Response("Invalid webhook", { status: 400 });
  }
}
