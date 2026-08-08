"use client";

import { useEffect, useState } from "react";
import Link from "next/link";

type Status = "pending" | "active" | "failed" | "refunded" | "revoked" | "disputed";

export function LicenseResult({ licenseKey, initialStatus }: { licenseKey: string; initialStatus: Status }) {
  const [status, setStatus] = useState(initialStatus);
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    if (status !== "pending") return;
    const timer = window.setInterval(async () => {
      const response = await fetch(`/api/licenses/status/${licenseKey}`, { cache: "no-store" });
      if (!response.ok) return;
      const next = (await response.json()) as { status: Status };
      setStatus(next.status);
    }, 1500);
    return () => window.clearInterval(timer);
  }, [licenseKey, status]);

  if (status !== "active") {
    const failed = status !== "pending";
    return (
      <section className="license-card">
        <div className={failed ? "license-symbol is-error" : "license-symbol"}>{failed ? "!" : "…"}</div>
        <h1>{failed ? "License unavailable" : "Preparing your license"}</h1>
        <p>{failed ? "This payment did not produce an active license. Please return to checkout or contact support." : "Payment received. This usually takes only a few seconds."}</p>
        {failed && <Link className="license-secondary" href="/checkout">Return to checkout</Link>}
      </section>
    );
  }

  return (
    <section className="license-card">
      <div className="license-symbol">✓</div>
      <p className="license-eyebrow">CURRENT LIFETIME LICENSE</p>
      <h1>{licenseKey}</h1>
      <p>Keep this key somewhere safe. It activates Current on up to three Macs.</p>
      <div className="license-actions">
        <a className="license-primary" href={`current://redeem/${licenseKey}`}>Open Current &amp; Redeem</a>
        <button
          className="license-secondary"
          onClick={async () => {
            await navigator.clipboard.writeText(licenseKey);
            setCopied(true);
            window.setTimeout(() => setCopied(false), 1800);
          }}
        >
          {copied ? "Copied" : "Copy license key"}
        </button>
        <a className="license-secondary" href="https://github.com/emilianscheel/current/releases/latest/download/Current.dmg">Download Current</a>
      </div>
      <p className="license-footnote">A Stripe receipt containing this key is also sent to your Apple Pay email.</p>
    </section>
  );
}
