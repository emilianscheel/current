# current website

The landing site, Apple Pay checkout, and license service for [current](https://github.com/emilianscheel/current).

## Local development

```bash
bun install
bun run db:migrate
bun run dev
```

Open [http://localhost:3000](http://localhost:3000).

## Validation

```bash
bun run lint
bun test
bun run build
```

## Deployment

Copy `.env.example` into the deployment environment and provide a Neon pooled PostgreSQL connection string plus Stripe test or live keys. No Stripe Product or Price is created: checkout creates a tax-inclusive $20 USD PaymentIntent for downloadable software at purchase time.

In the Stripe Dashboard:

1. Enable Stripe Tax, set the merchant origin address, and add the jurisdictions where Current is registered to collect tax.
2. Register every checkout domain and subdomain under Payment method domains in both sandbox and live mode.
3. Enable Apple Pay/card payments and successful-payment receipt emails.
4. Add `https://<domain>/api/stripe/webhook` and subscribe to `payment_intent.succeeded`, `payment_intent.payment_failed`, `charge.refunded`, and `charge.dispute.closed`; store its signing secret as `STRIPE_WEBHOOK_SECRET`.

Apple Pay requires HTTPS and a supported Mac/browser with Wallet configured. For local Stripe webhook testing, forward events with the Stripe CLI and use the emitted signing secret.
