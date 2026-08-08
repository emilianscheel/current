import "server-only";

import { neon } from "@neondatabase/serverless";
import { drizzle } from "drizzle-orm/neon-http";
import * as schema from "./schema";

let cached: ReturnType<typeof createDatabase> | undefined;

function createDatabase() {
  const url = process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is not configured");
  return drizzle(neon(url), { schema });
}

export function database() {
  cached ??= createDatabase();
  return cached;
}
