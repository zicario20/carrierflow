# CarrierFlow

[![Verification](https://github.com/zicario20/carrierflow/actions/workflows/verify.yml/badge.svg?branch=main)](https://github.com/zicario20/carrierflow/actions/workflows/verify.yml)

**A privacy-first carrier operations platform for owners, dispatchers, and drivers.**

CarrierFlow brings load execution, fleet assignment, dispatch pricing, driver workflows, evidence capture, tracking, and pilot controls into one multi-tenant system. It is designed around operational safety: every role sees only the information it is allowed to use, critical state changes are auditable, and offline work is replay-safe.

## Why this project stands out

- **Security is part of the domain model.** PostgreSQL row-level security, tenant-scoped database functions, immutable audit records, private evidence validation, and revocable public tracking capabilities protect operational data at the source.
- **Built for real dispatch work.** Load state transitions, required evidence, driver/vehicle assignment, route estimate revisions, and carrier capacity limits are enforced server-side rather than trusted to the UI.
- **Two production clients, one contract.** A Next.js operations console and a Flutter driver app share durable database rules while optimizing for their distinct workflows.
- **Deliberate failure handling.** Offline driver actions use a secure outbox and idempotency keys; background location and notifications explicitly model permission, connectivity, freshness, and operating-system limits.
- **Self-hosted by design.** Docker Compose and Dokploy-ready deployment assets keep the platform deployable on a single Ubuntu server without treating a managed SaaS as a requirement.

## Architecture at a glance

| Layer | Technology | Responsibility |
| --- | --- | --- |
| Operations console | Next.js 16 + TypeScript | Dispatch, fleet, pricing, pilot controls, and public tracking capabilities |
| Driver experience | Flutter + Dart | Authorized load execution, evidence, offline replay, consented tracking, and push refresh |
| Data plane | PostgreSQL + Supabase | Multi-tenancy, RLS, database-authorized workflows, storage validation, auditability |
| Delivery | Firebase Admin + private worker | Encrypted device registration and minimal notification delivery |
| Deployment | Docker Compose + Dokploy | TLS edge proxy, private service networks, scoped secrets, data volumes, and release gates |

## Engineering highlights

### Multi-tenant security

Every business record is organization-scoped. Database policies and security-definer functions enforce role, tenant, state, and idempotency checks. Clients do not get service-role credentials or authority to choose a company, driver, or load scope.

### Operational state machine

Loads move through an auditable lifecycle. Dispatch owns assignment and cancellation; drivers can execute only their own authorized next step. Delivery is blocked until configured evidence requirements are satisfied.

### Offline-safe driver workflow

The mobile app persists ordered actions before sending them. Reconnects replay the original intent using a UUID, so a late network response cannot create a second delivery, evidence record, or incident.

### Privacy-aware tracking and sharing

Current location is separated from retained history. Visibility requires an active context, stale coordinates are withheld, detailed GPS is retained for seven days, and public tracking links are opaque, scoped, expiring, and revocable.

### Pilot controls without billing scope

Private-pilot entitlements enforce carrier capacity atomically. The system exposes trial and plan state without checkout, payment collection, or a billing provider.

## Repository layout

```text
apps/admin/       Next.js operations console
apps/driver/      Flutter driver application
packages/         Shared routing and design-token contracts
supabase/         PostgreSQL migrations, RLS policies, and pgTAP contracts
infra/dokploy/    Production Compose and Traefik configuration
scripts/          Local verification and release-support tooling
tests/            Browser security and accessibility coverage
```

## Local development

### Prerequisites

- Node.js `24.20+`
- pnpm `11+`
- Docker Desktop for the local Supabase stack
- Flutter `3.47.2` / Dart `3.13.2` for the driver app

```bash
corepack enable
pnpm install --frozen-lockfile
pnpm exec supabase start
pnpm exec supabase db reset
pnpm --filter @carrierflow/admin dev
```

In a separate terminal:

```bash
pnpm --filter @carrierflow/admin test
pwsh -NoProfile -File scripts/test-driver-windows.ps1
```

## Quality signals

The current verification suite covers database authorization, cross-tenant denial, idempotent replay, accessibility landmarks, bilingual operation flows, web builds, and Flutter analysis.

```bash
pnpm exec supabase test db
pnpm --filter @carrierflow/admin test
pnpm --filter @carrierflow/admin build
pnpm exec playwright test
pnpm audit --prod --audit-level=high
```

## Deployment

The repository includes a Dokploy-ready Compose topology with a TLS-only public edge, internal service networks, scoped environment files, controlled admin egress for FCM, persistent volumes, a protected push dispatcher, and a safe local restore dry-run verifier.

Before a private pilot, follow the [release-gates runbook](docs/operations/private-pilot-release-gates.md). It intentionally distinguishes verified automation from manual checks such as physical Android/iOS validation, host firewall configuration, and an off-server restoration exercise.

## Product direction

CarrierFlow is US-first and USD-first for carrier operations. It supports bilingual English/Spanish workflows, privacy-conscious GPS collection, and assignment-driven load execution. Payroll, public checkout, and unverified truck-safe routing are intentionally outside the current scope.