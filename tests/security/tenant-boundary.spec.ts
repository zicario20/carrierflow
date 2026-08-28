import { expect, test } from "@playwright/test";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const repositoryRoot = resolve(import.meta.dirname, "../..");
const composePath = join(repositoryRoot, "infra", "dokploy", "docker-compose.production.yml");
const restoreScriptPath = join(repositoryRoot, "scripts", "verify-local-restore.mjs");
const workflowPath = join(repositoryRoot, ".github", "workflows", "verify.yml");

function composeService(compose: string, serviceName: string, nextServiceName: string): string {
  const start = compose.indexOf(`\n  ${serviceName}:`);
  const end = compose.indexOf(`\n  ${nextServiceName}:`, start + 1);
  expect(start, `${serviceName} must exist in Compose`).toBeGreaterThanOrEqual(0);
  expect(end, `${nextServiceName} must follow ${serviceName} in Compose`).toBeGreaterThan(start);
  return compose.slice(start, end);
}

test("keeps tenant data services and the push secret off the public edge", async () => {
  const compose = await readFile(composePath, "utf8");

  expect(compose).toContain("edge_public:");
  expect(compose).toContain("app_private:");
  expect(compose).toContain("data_private:");
  expect(compose).toContain("monitor_private:");
  expect(compose).toContain("CARRIERFLOW_TRAEFIK_IMAGE");
  expect(compose).toContain("--api.dashboard=false");
  expect(compose).toContain("tmpfs:");
  expect(compose).toContain("- /tmp");
  expect(compose).not.toContain("docker.sock");
  expect(compose).toMatch(/ports:\s*\n\s*- "80:80"\s*\n\s*- "443:443"/);
  expect(compose).not.toMatch(/- "(?:3000|5432|8000|9000|9090):/);
  expect(compose).toContain("/api/internal/push/dispatch");
  expect(compose).toContain("x-carrierflow-push-worker-secret");
  expect(compose).toContain("$${PUSH_WORKER_SECRET}");
  expect(compose).not.toContain("PUSH_WORKER_SECRET=");
  expect(compose).toContain("supabase_db_data:");
  expect(compose).toContain("supabase_storage_data:");
  expect(compose).toContain("monitoring_data:");
});

test("gives each production service only its own non-versioned environment file", async () => {
  const compose = await readFile(composePath, "utf8");
  const admin = composeService(compose, "carrierflow-admin", "push-dispatcher");
  const dispatcher = composeService(compose, "push-dispatcher", "supabase-db");
  const database = composeService(compose, "supabase-db", "supabase-api");
  const api = composeService(compose, "supabase-api", "supabase-storage");
  const storage = composeService(compose, "supabase-storage", "monitoring");
  const monitoring = compose.slice(compose.indexOf("  monitoring:"), compose.indexOf("\nnetworks:"));

  expect(compose).not.toContain("CARRIERFLOW_RUNTIME_ENV_FILE");
  expect(admin).toContain("CARRIERFLOW_ADMIN_ENV_FILE");
  expect(dispatcher).toContain("CARRIERFLOW_PUSH_DISPATCHER_ENV_FILE");
  expect(database).toContain("CARRIERFLOW_SUPABASE_DB_ENV_FILE");
  expect(api).toContain("CARRIERFLOW_SUPABASE_API_ENV_FILE");
  expect(storage).toContain("CARRIERFLOW_SUPABASE_STORAGE_ENV_FILE");
  expect(monitoring).toContain("CARRIERFLOW_MONITORING_ENV_FILE");
  expect(dispatcher).toContain("PUSH_WORKER_SECRET");
  expect(dispatcher).not.toContain("SUPABASE_SERVICE_ROLE_KEY");
  expect(dispatcher).not.toContain("PUSH_TOKEN_ENCRYPTION_KEY");
  expect(dispatcher).not.toContain("FCM_SERVICE_ACCOUNT_JSON");
});

test("gives only the admin workload controlled outbound TLS access", async () => {
  const compose = await readFile(composePath, "utf8");
  const admin = composeService(compose, "carrierflow-admin", "push-dispatcher");
  const dispatcher = composeService(compose, "push-dispatcher", "supabase-db");
  const database = composeService(compose, "supabase-db", "supabase-api");
  const api = composeService(compose, "supabase-api", "supabase-storage");
  const storage = composeService(compose, "supabase-storage", "monitoring");
  const monitoring = compose.slice(compose.indexOf("  monitoring:"), compose.indexOf("\nnetworks:"));

  expect(compose).toContain("egress_controlled: {}");
  expect(admin).toContain("egress_controlled");
  for (const service of [dispatcher, database, api, storage, monitoring]) {
    expect(service).not.toContain("egress_controlled");
  }
  expect(admin).not.toMatch(/ports:/);
});

test("never turns a local restore dry-run into a production or off-server restore claim", async () => {
  const disposableDirectory = await mkdtemp(join(tmpdir(), "carrierflow-restore-dry-run-"));
  const metadataPath = join(disposableDirectory, "backup-metadata.json");

  try {
    await writeFile(
      join(disposableDirectory, ".carrierflow-disposable-restore"),
      "carrierflow-disposable-restore-v1\n",
      "utf8",
    );
    await writeFile(
      metadataPath,
      JSON.stringify({
        backupId: "local-fixture-20260828",
        createdAt: "2026-08-28T00:00:00.000Z",
        encrypted: true,
        format: "carrierflow-local-restore-dry-run-v1",
        source: "disposable-local-test",
      }),
      "utf8",
    );

    const result = await execFileAsync(process.execPath, [
      restoreScriptPath,
      "--dry-run",
      "--directory",
      disposableDirectory,
      "--metadata",
      metadataPath,
    ]);

    expect(result.stdout).toContain("LOCAL RESTORE DRY RUN ONLY");
    expect(result.stdout).toContain("No database, object storage, network, or container restore was performed.");
    expect(result.stdout).toContain("This does not verify an off-server backup or a production restore.");
  } finally {
    await rm(disposableDirectory, { force: true, recursive: true });
  }
});

test("returns the same private no-store response for an invalid opaque public capability", async ({ request }) => {
  const response = await request.get(`/api/public/track/${"0".repeat(64)}`);

  expect(response.status()).toBe(404);
  expect(response.headers()["cache-control"]).toBe("no-store");
  expect(await response.text()).toBe("");
});

test("keeps release verification duties isolated in CI without injecting runtime credentials", async () => {
  const workflow = await readFile(workflowPath, "utf8");

  for (const job of ["typecheck:", "lint:", "unit:", "pgtap:", "admin-build:", "critical-e2e:", "flutter:"]) {
    expect(workflow).toContain(job);
  }
  expect(workflow).toContain("pnpm typecheck");
  expect(workflow).toContain("pnpm lint");
  expect(workflow).toContain("pnpm test");
  expect(workflow).toContain("pnpm exec supabase test db");
  expect(workflow).toContain("pnpm --filter @carrierflow/admin build");
  expect(workflow).toContain("pnpm exec playwright test");
  expect(workflow).toContain("tests/security/tenant-boundary.spec.ts");
  expect(workflow).toContain("tests/a11y/critical-flows.spec.ts");
  expect(workflow).toContain("scripts/test-driver-windows.ps1");
  expect(workflow).not.toMatch(/PUSH_WORKER_SECRET:\s*[^${\s]/);
  expect(workflow).not.toMatch(/SUPABASE_SERVICE_ROLE_KEY:\s*[^${\s]/);
});
