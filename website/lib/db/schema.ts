import {
  bigint,
  check,
  index,
  pgEnum,
  pgTable,
  text,
  timestamp,
  uniqueIndex,
  uuid,
  varchar,
} from "drizzle-orm/pg-core";
import { sql } from "drizzle-orm";

export const licenseStatus = pgEnum("license_status", [
  "pending",
  "active",
  "failed",
  "refunded",
  "revoked",
  "disputed",
]);

export const users = pgTable(
  "users",
  {
    id: uuid("id").defaultRandom().primaryKey(),
    email: text("email").notNull(),
    stripeCustomerId: text("stripe_customer_id").notNull(),
    createdAt: timestamp("created_at", { withTimezone: true }).defaultNow().notNull(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).defaultNow().notNull(),
  },
  (table) => [
    uniqueIndex("users_email_unique").on(table.email),
    uniqueIndex("users_stripe_customer_unique").on(table.stripeCustomerId),
  ],
);

export const licenses = pgTable(
  "licenses",
  {
    id: varchar("id", { length: 11 }).primaryKey(),
    userId: uuid("user_id").references(() => users.id, { onDelete: "set null" }),
    status: licenseStatus("status").default("pending").notNull(),
    stripePaymentIntentId: text("stripe_payment_intent_id"),
    stripeTaxCalculationId: text("stripe_tax_calculation_id"),
    amountTotal: bigint("amount_total", { mode: "number" }).default(2000).notNull(),
    amountTax: bigint("amount_tax", { mode: "number" }).default(0).notNull(),
    currency: varchar("currency", { length: 3 }).default("usd").notNull(),
    purchasedAt: timestamp("purchased_at", { withTimezone: true }),
    createdAt: timestamp("created_at", { withTimezone: true }).defaultNow().notNull(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).defaultNow().notNull(),
  },
  (table) => [
    check("licenses_id_format", sql`${table.id} ~ '^[A-Z0-9]{3}-[A-Z0-9]{3}-[A-Z0-9]{3}$'`),
    uniqueIndex("licenses_payment_intent_unique").on(table.stripePaymentIntentId),
    index("licenses_user_idx").on(table.userId),
  ],
);

export const activations = pgTable(
  "activations",
  {
    id: uuid("id").defaultRandom().primaryKey(),
    licenseId: varchar("license_id", { length: 11 })
      .notNull()
      .references(() => licenses.id, { onDelete: "cascade" }),
    deviceHash: varchar("device_hash", { length: 64 }).notNull(),
    activatedAt: timestamp("activated_at", { withTimezone: true }).defaultNow().notNull(),
    deactivatedAt: timestamp("deactivated_at", { withTimezone: true }),
    lastValidatedAt: timestamp("last_validated_at", { withTimezone: true })
      .defaultNow()
      .notNull(),
  },
  (table) => [
    uniqueIndex("activations_license_device_unique").on(
      table.licenseId,
      table.deviceHash,
    ),
    index("activations_license_active_idx").on(
      table.licenseId,
      table.deactivatedAt,
    ),
  ],
);

export const webhookEvents = pgTable("webhook_events", {
  id: text("id").primaryKey(),
  type: text("type").notNull(),
  processedAt: timestamp("processed_at", { withTimezone: true }).defaultNow().notNull(),
});
