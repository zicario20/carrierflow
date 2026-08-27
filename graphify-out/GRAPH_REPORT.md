# Graph Report - Carrier Flow  (2026-08-27)

## Corpus Check
- 23 files · ~18,955 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 97 nodes · 85 edges · 16 communities (14 shown, 2 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `c3f9df3a`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- scripts
- Dokploy production Compose exposes only the TLS proxy and isolates application, self-hosted Supabase/data, and monitoring; backup restore, security, accessibility, device, and CI evidence gate pilot release.
- devDependencies
- compilerOptions
- All records and queries are organization-scoped with server-side authorization and database RLS; client filtering is never authorization.
- paths
- Accepted decision: operate Dokploy on owner-controlled Ubuntu with Docker Compose and official Docker-based self-hosted Supabase for the private pilot.
- CarrierFlow is a US/USD multi-tenant B2B private-invitation pilot for carriers, owners, dispatchers, and drivers; Canadian trips do not add Canadian commercial scope.
- Architect, Superpowers, Cyber Neo, UI UX Pro Max, and Graphify have distinct delivery ownership; Graphify is consulted before broad exploration and updated after durable changes.
- Private evidence needs authorized short-lived signed access, while public tracking is a load-scoped expiring/revocable minimal-data token with no session creation.
- Workspace execution contract mandates authorized service/RPC architecture, current/history location separation, TLS-only public exposure, domain rules before edits, and declared verification commands.
- pnpm workspace intentionally includes only apps and packages, excluding blueprint artifacts from the application workspace.
- File and authority map
- package.json

## God Nodes (most connected - your core abstractions)
1. `compilerOptions` - 9 edges
2. `scripts` - 8 edges
3. `File and authority map` - 5 edges
4. `paths` - 4 edges
5. `exclude` - 4 edges
6. `Accepted decision: operate Dokploy on owner-controlled Ubuntu with Docker Compose and official Docker-based self-hosted Supabase for the private pilot.` - 4 edges
7. `CarrierFlow Pilot Build Implementation Plan` - 3 edges
8. `Dokploy production Compose exposes only the TLS proxy and isolates application, self-hosted Supabase/data, and monitoring; backup restore, security, accessibility, device, and CI evidence gate pilot release.` - 3 edges
9. `Administrative and operational load states are server-only; delivery requires pickup plus configured evidence, while incidents preserve the active load.` - 3 edges
10. `Flutter persists mutations before networking and represents denied, approximate, stale, and force-quit location states as degraded; background tracking is best effort for active loads.` - 3 edges

## Surprising Connections (you probably didn't know these)
- `Server-enforced auditable transitions, configurable evidence, consented GPS, durable offline idempotency, scoped public links, and bilingual accessible UX are inseparable product requirements.` --implements--> `Administrative and operational load states are server-only; delivery requires pickup plus configured evidence, while incidents preserve the active load.`  [EXTRACTED]
  AGENTS.md → blueprints/carrierflow/blueprint.md
- `Server-enforced auditable transitions, configurable evidence, consented GPS, durable offline idempotency, scoped public links, and bilingual accessible UX are inseparable product requirements.` --implements--> `Location sampling is consented, minimized, freshness-labeled, and retained by policy; local critical mutations have UUID idempotency, ordering, server-result confirmation, and retry state.`  [EXTRACTED]
  AGENTS.md → docs/product/carrierflow-prd.md
- `Dokploy production Compose exposes only the TLS proxy and isolates application, self-hosted Supabase/data, and monitoring; backup restore, security, accessibility, device, and CI evidence gate pilot release.` --implements--> `Before pilot, require hardened host access, no public database/internal panels, deployment-injected secrets, encrypted off-host backups, recorded isolated restore, versioned rollback, monitoring, and Cyber Neo review.`  [EXTRACTED]
  blueprints/carrierflow/blueprint.md → docs/architecture/adr-001-self-hosted-dokploy.md
- `Pilot requires automated policy tests, physical mobile checks, Cyber Neo remediation report, UI UX review, reproducible Dokploy deployment, encrypted off-host backup, and tested restoration.` --implements--> `Dokploy production Compose exposes only the TLS proxy and isolates application, self-hosted Supabase/data, and monitoring; backup restore, security, accessibility, device, and CI evidence gate pilot release.`  [EXTRACTED]
  docs/superpowers/specs/2026-08-27-carrierflow-design.md → blueprints/carrierflow/blueprint.md
- `Administrative and operational load states are server-only; delivery requires pickup plus configured evidence, while incidents preserve the active load.` --implements--> `Ordered-stop loads support multi-stop data despite a one-pickup/one-delivery pilot UI; invalid delivery is rejected, reassignment is audited, and incidents require resolution without auto-cancellation.`  [EXTRACTED]
  blueprints/carrierflow/blueprint.md → docs/product/carrierflow-prd.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **The three epics form the ordered implementation sequence from governed tenant foundation to dispatch execution to pilot reliability and release evidence.** — blueprints_carrierflow_epics_01_foundation_tenant_audit_a11y, blueprints_carrierflow_epics_02_dispatch_operational_execution, blueprints_carrierflow_epics_03_reliability_pilot_release [EXTRACTED 1.00]
- **Pilot readiness combines self-hosted operational controls, reliability/release implementation, and cross-role physical, security, accessibility, and restore review.** — docs_architecture_adr_001_self_hosted_dokploy_pre_pilot_controls, blueprints_carrierflow_epics_03_reliability_pilot_release, docs_superpowers_specs_2026_08_27_carrierflow_design_pre_pilot_review_gates [EXTRACTED 1.00]
- **Tenant authorization, server-audited state/evidence enforcement, and durable offline idempotency jointly define a retry-safe trusted mutation boundary.** — agents_tenant_authorization_boundary, blueprints_carrierflow_blueprint_load_state_and_evidence_contract, docs_product_carrierflow_prd_privacy_offline_contract [INFERRED 0.95]

## Communities (16 total, 2 thin omitted)

### Community 0 - "scripts"
Cohesion: 0.25
Nodes (8): scripts, db:reset, db:start, db:test, lint, test, test:e2e, typecheck

### Community 1 - "Dokploy production Compose exposes only the TLS proxy and isolates application, self-hosted Supabase/data, and monitoring; backup restore, security, accessibility, device, and CI evidence gate pilot release."
Cohesion: 0.18
Nodes (11): Server-enforced auditable transitions, configurable evidence, consented GPS, durable offline idempotency, scoped public links, and bilingual accessible UX are inseparable product requirements., Dokploy production Compose exposes only the TLS proxy and isolates application, self-hosted Supabase/data, and monitoring; backup restore, security, accessibility, device, and CI evidence gate pilot release., Administrative and operational load states are server-only; delivery requires pickup plus configured evidence, while incidents preserve the active load., Flutter persists mutations before networking and represents denied, approximate, stale, and force-quit location states as degraded; background tracking is best effort for active loads., Dispatch sequence models ordered loads/evidence/state, versioned pricing estimates, mandatory web assignment, and a current-first Flutter execution flow., Reliability sequence adds exactly-once offline sync, privacy-safe tracking, minimal push/public links, pilot entitlements and Dokploy/CI security-accessibility gates., Driver UX is current-load-first, has no decision controls, uses durable ordered client_mutation_id retries, and reports platform-limited tracking honestly., Before pilot, require hardened host access, no public database/internal panels, deployment-injected secrets, encrypted off-host backups, recorded isolated restore, versioned rollback, monitoring, and Cyber Neo review. (+3 more)

### Community 2 - "devDependencies"
Cohesion: 0.15
Nodes (13): devDependencies, @playwright/test, shadcn, supabase, tailwindcss, typescript, vitest, @playwright/test (+5 more)

### Community 3 - "compilerOptions"
Cohesion: 0.15
Nodes (12): compilerOptions, baseUrl, module, moduleResolution, noImplicitOverride, noUncheckedIndexedAccess, strict, target (+4 more)

### Community 4 - "All records and queries are organization-scoped with server-side authorization and database RLS; client filtering is never authorization."
Cohesion: 0.20
Nodes (10): Only authorized admin/dispatcher roles can assign, reassign, cancel, or close loads; drivers never receive those controls., All records and queries are organization-scoped with server-side authorization and database RLS; client filtering is never authorization., Web and Flutter use validated server handlers/RPC; direct table mutations are prohibited and authorized mutations are transactional, RLS-protected, audited, and typed., Empty, loaded, total estimated miles, and quote per total mile are separately persisted; next-load deadhead begins at the active load's final planned stop and invalidations create immutable revisions and notifications., Foundation sequence establishes reproducible workspace, tenant/RLS schema, invitations and audit, bilingual accessible admin shell, and eligible fleet shifts., Database changes are forward-only; every commercial table has company_id/RLS, SECURITY DEFINER is constrained, audits share the mutation transaction, and private storage is tenant-prefixed., The operational light-first UI uses approved tokens, non-color state cues, 44px targets, keyboard/focus/landmarks, EN/ES parity, and reduced motion., Dispatcher-entered USD quote yields separate empty, loaded, total, and quote-per-total-mile values; calculations are auditable estimates and driver compensation visibility is dispatch-authorized. (+2 more)

### Community 5 - "paths"
Cohesion: 0.29
Nodes (7): paths, @carrierflow/contracts/*, @carrierflow/design-tokens/*, @carrierflow/routing-contract/*, packages/contracts/src/*, packages/design-tokens/src/*, packages/routing-contract/src/*

### Community 6 - "Accepted decision: operate Dokploy on owner-controlled Ubuntu with Docker Compose and official Docker-based self-hosted Supabase for the private pilot."
Cohesion: 0.33
Nodes (6): Production is self-hosted Ubuntu/Dokploy/Compose with private networks, TLS proxy, backups, monitoring, rollback, and explicit single-host limits; no real pilot billing., Self-hosting minimizes recurring subscriptions while preserving data and operational control, but cheap infrastructure without recovery, isolation, or maintenance is unacceptable., ADR cites official Dokploy core/installation and Supabase self-hosting/Docker documentation as deployment references., Accepted decision: operate Dokploy on owner-controlled Ubuntu with Docker Compose and official Docker-based self-hosted Supabase for the private pilot., PRD cites official Dokploy, Supabase, platform location, FCM, MapLibre, routing, and future Stripe documentation., Dokploy/Compose self-hosting does not replace backups, restore tests, hardening, monitoring, capacity planning, or explicit single-server availability limits.

### Community 7 - "CarrierFlow is a US/USD multi-tenant B2B private-invitation pilot for carriers, owners, dispatchers, and drivers; Canadian trips do not add Canadian commercial scope."
Cohesion: 0.40
Nodes (5): PRD and blueprint are binding contracts; conflict requires a decision-record update before implementation., MVP excludes driver offers, payroll, ELD/load boards, truck-safe routing claims, pilot checkout, Canadian billing, and multi-region HA to keep operations safe and bounded., Approved 15-step greenfield build contract for a US-first bilingual CarrierFlow private pilot., Starter/Growth/Fleet active-driver capacity is enforced from the outset, but pilot entitlements expose trial/upgrade context without real charge or checkout until launch approval., CarrierFlow is a US/USD multi-tenant B2B private-invitation pilot for carriers, owners, dispatchers, and drivers; Canadian trips do not add Canadian commercial scope.

### Community 8 - "Architect, Superpowers, Cyber Neo, UI UX Pro Max, and Graphify have distinct delivery ownership; Graphify is consulted before broad exploration and updated after durable changes."
Cohesion: 0.67
Nodes (3): Architect, Superpowers, Cyber Neo, UI UX Pro Max, and Graphify have distinct delivery ownership; Graphify is consulted before broad exploration and updated after durable changes., Five tracked project-scoped skills are required build artifacts; governance augments but never replaces them, and bootstrap is idempotent without overwriting existing artifacts., CarrierFlow governance assigns architecture, disciplined implementation, security remediation, UX accessibility, and graph memory to named roles while allowing safe autonomous action.

### Community 9 - "Private evidence needs authorized short-lived signed access, while public tracking is a load-scoped expiring/revocable minimal-data token with no session creation."
Cohesion: 0.67
Nodes (3): Private evidence needs authorized short-lived signed access, while public tracking is a load-scoped expiring/revocable minimal-data token with no session creation., HTTP/RPC inputs require typed safe errors; credentials stay out of clients/logs; public tokens are opaque, hashed, scoped, expiring, revocable, and rate-limited., Evidence is configurable and private; optional public tracking exposes only agreed single-load status/ETA/location through a revocable expiring opaque secret and excludes private documents and fleet data.

### Community 14 - "File and authority map"
Cohesion: 0.25
Nodes (7): CarrierFlow Pilot Build Implementation Plan, Coverage review, File and authority map, Task 1: Freeze the approved execution contract, Task 2: Bootstrap a dedicated implementation worktree, Task 3: Execute the 15-task DAG in three reviewable epics, Task 4: Certify the private-pilot gate

### Community 15 - "package.json"
Cohesion: 0.33
Nodes (5): engines, node, name, packageManager, private

## Knowledge Gaps
- **53 isolated node(s):** `name`, `private`, `packageManager`, `node`, `typecheck` (+48 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **2 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `devDependencies` connect `devDependencies` to `package.json`?**
  _High betweenness centrality (0.050) - this node is a cross-community bridge._
- **Why does `scripts` connect `scripts` to `package.json`?**
  _High betweenness centrality (0.034) - this node is a cross-community bridge._
- **Why does `compilerOptions` connect `compilerOptions` to `paths`?**
  _High betweenness centrality (0.031) - this node is a cross-community bridge._
- **What connects `name`, `private`, `packageManager` to the rest of the system?**
  _53 weakly-connected nodes found - possible documentation gaps or missing edges._