import { describe, expect, test } from "vitest";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const migrationPath = resolve(
  process.cwd(),
  "../../supabase/migrations/0017_sync_operations.sql",
);

describe("driver sync idempotency contract", () => {
  test("defines zero-scope receipts that preserve the original result for state and evidence replay", async () => {
    const migration = await readFile(migrationPath, "utf8");

    expect(migration).toContain("driver_sync_receipts");
    expect(migration).toContain("primary key (actor_id, client_mutation_id)");
    expect(migration).toContain("advance_own_driver_load_state_idempotent(");
    expect(migration).toContain("record_own_driver_load_evidence_idempotent(");
    expect(migration).toContain("request_fingerprint");
    expect(migration).toContain("pg_advisory_xact_lock");
    expect(migration).toContain("enable row level security");
    expect(migration).toContain("force row level security");
    expect(migration).not.toContain("target_company_id uuid");
    expect(migration).not.toContain("target_driver_id uuid");
    expect(migration).not.toContain("target_load_id uuid");
  });
});
