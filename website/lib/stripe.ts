import "server-only";

import Stripe from "stripe";

let cached: Stripe | undefined;

export function stripeClient(): Stripe {
  const key = process.env.STRIPE_SECRET_KEY;
  if (!key) throw new Error("STRIPE_SECRET_KEY is not configured");
  cached ??= new Stripe(key);
  return cached;
}
