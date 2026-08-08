"use client";

import { useMemo, useState } from "react";
import Image from "next/image";
import { useRouter } from "next/navigation";
import { Elements, ExpressCheckoutElement, useElements, useStripe } from "@stripe/react-stripe-js";
import { loadStripe } from "@stripe/stripe-js";
import type { StripeExpressCheckoutElementOptions } from "@stripe/stripe-js";

const features = [
  "Hold fn to dictate anywhere",
  "Private on-device transcription",
  "Context-aware prompt writing",
  "Five supported languages",
  "Local searchable context",
];

function ApplePayButton() {
  const stripe = useStripe();
  const elements = useElements();
  const router = useRouter();
  const [available, setAvailable] = useState<boolean | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const options: StripeExpressCheckoutElementOptions = {
    billingAddressRequired: true,
    emailRequired: true,
    buttonHeight: 50,
    buttonTheme: { applePay: "black" },
    buttonType: { applePay: "buy" },
    paymentMethods: {
      applePay: "always",
      googlePay: "never",
      link: "never",
      amazonPay: "never",
      paypal: "never",
      klarna: "never",
    },
    layout: { maxColumns: 1, maxRows: 1, overflow: "never" },
    lineItems: [{ name: "Current lifetime license — tax included", amount: 2000 }],
  };

  return (
    <div className="receipt-payment">
      <div className={busy ? "stripe-wallet is-busy" : "stripe-wallet"}>
        <ExpressCheckoutElement
          options={options}
          onAvailablePaymentMethodsChange={({ paymentMethods }) =>
            setAvailable(paymentMethods?.applePay?.available === true)
          }
          onConfirm={async () => {
            if (!stripe || !elements || busy) return;
            setBusy(true);
            setError("");
            const submitted = await elements.submit();
            if (submitted.error) {
              setError(submitted.error.message ?? "Apple Pay could not start.");
              setBusy(false);
              return;
            }
            const origin = window.location.origin;
            const created = await stripe.createConfirmationToken({
              elements,
              params: { return_url: `${origin}/checkout/complete` },
            });
            if (created.error || !created.confirmationToken) {
              setError(created.error?.message ?? "Payment details could not be read.");
              setBusy(false);
              return;
            }
            const response = await fetch("/api/checkout/intent", {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ confirmationTokenId: created.confirmationToken.id }),
            });
            const result = (await response.json()) as {
              clientSecret?: string;
              licenseKey?: string;
              error?: string;
            };
            if (!response.ok || !result.clientSecret || !result.licenseKey) {
              setError(result.error ?? "Checkout could not be created.");
              setBusy(false);
              return;
            }
            const confirmed = await stripe.confirmPayment({
              clientSecret: result.clientSecret,
              confirmParams: { confirmation_token: created.confirmationToken.id },
              redirect: "if_required",
            });
            if (confirmed.error) {
              setError(confirmed.error.message ?? "Payment was not completed.");
              setBusy(false);
              return;
            }
            router.push(`/${result.licenseKey}`);
          }}
        />
      </div>
      {available === false && (
        <p className="wallet-message">Apple Pay isn’t available in this browser or Wallet.</p>
      )}
      {busy && <p className="wallet-message">Finishing your purchase…</p>}
      {error && <p className="wallet-message wallet-error">{error}</p>}
    </div>
  );
}

export function CheckoutReceipt({ publishableKey }: { publishableKey: string }) {
  const stripe = useMemo(() => (publishableKey ? loadStripe(publishableKey) : null), [publishableKey]);
  const [formattedDate] = useState(() =>
    new Intl.DateTimeFormat("en-US", {
      dateStyle: "short",
      timeStyle: "short",
    }).format(new Date()),
  );

  return (
    <article className="receipt" aria-label="Buy Current">
      <header className="receipt-header">
        <Image src="/apple-icon.png" width={58} height={58} alt="Current app icon" priority />
        <p className="receipt-date" suppressHydrationWarning>DATE: {formattedDate}</p>
      </header>
      <div className="receipt-rule" />
      <section className="receipt-features" aria-label="Included features">
        {features.map((feature) => (
          <div className="receipt-row" key={feature}>
            <span>{feature}</span><span>INCL.</span>
          </div>
        ))}
      </section>
      <div className="receipt-rule" />
      <section className="receipt-totals" aria-label="Purchase total">
        <div className="receipt-row receipt-total"><span>Total</span><span>$20.00</span></div>
      </section>
      <div className="receipt-barcode" aria-hidden="true" />
      {stripe ? (
        <Elements
          stripe={stripe}
          options={{
            mode: "payment",
            amount: 2000,
            currency: "usd",
            paymentMethodTypes: ["card"],
            appearance: { variables: { borderRadius: "8px" } },
          }}
        >
          <ApplePayButton />
        </Elements>
      ) : (
        <p className="wallet-message wallet-error">Checkout is not configured yet.</p>
      )}
    </article>
  );
}
