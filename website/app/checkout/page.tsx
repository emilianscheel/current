import type { Metadata } from "next";
import { CheckoutReceipt } from "./receipt";

export const metadata: Metadata = {
  title: "Buy Current",
  description: "A lifetime Current license for $20, tax included.",
};

export default function CheckoutPage() {
  return (
    <main className="checkout-page">
      <CheckoutReceipt publishableKey={process.env.NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY ?? ""} />
    </main>
  );
}
