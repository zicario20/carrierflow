# Graph Report - phase-1-foundation  (2026-08-28)

## Corpus Check
- 64 files · ~30,660 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 322 nodes · 374 edges · 34 communities (31 shown, 3 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `ffc81175`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- compilerOptions
- fleet-service.ts
- devDependencies
- scripts
- scripts
- dependencies
- compilerOptions
- All records and queries are organization-scoped with server-side authorization and database RLS; client filtering is never authorization.
- write-audit.ts
- compilerOptions
- File and authority map
- env.ts
- Accepted decision: operate Dokploy on owner-controlled Ubuntu with Docker Compose and official Docker-based self-hosted Supabase for the private pilot.
- CarrierFlow is a US/USD multi-tenant B2B private-invitation pilot for carriers, owners, dispatchers, and drivers; Canadian trips do not add Canadian commercial scope.
- Q: How do mandatory assignment, mileage revisions, and tenant security constrain the private pilot?
- Architect, Superpowers, Cyber Neo, UI UX Pro Max, and Graphify have distinct delivery ownership; Graphify is consulted before broad exploration and updated after durable changes.
- layout.tsx
- Private evidence needs authorized short-lived signed access, while public tracking is a load-scoped expiring/revocable minimal-data token with no session creation.
- next-env.d.ts
- Workspace execution contract mandates authorized service/RPC architecture, current/history location separation, TLS-only public exposure, domain rules before edits, and declared verification commands.
- pnpm workspace intentionally includes only apps and packages, excluding blueprint artifacts from the application workspace.
- Design System Master File

## God Nodes (most connected - your core abstractions)
1. `ok()` - 12 edges
2. `validationError()` - 11 edges
3. `compilerOptions` - 10 edges
4. `authorize()` - 9 edges
5. `databaseFailure()` - 9 edges
6. `compilerOptions` - 9 edges
7. `mutateOwnShift()` - 8 edges
8. `forbidden()` - 8 edges
9. `scripts` - 8 edges
10. `scripts` - 8 edges

## Surprising Connections (you probably didn't know these)
- `Production is self-hosted Ubuntu/Dokploy/Compose with private networks, TLS proxy, backups, monitoring, rollback, and explicit single-host limits; no real pilot billing.` --implements--> `Accepted decision: operate Dokploy on owner-controlled Ubuntu with Docker Compose and official Docker-based self-hosted Supabase for the private pilot.`  [EXTRACTED]
  AGENTS.md → docs/architecture/adr-001-self-hosted-dokploy.md
- `PRD and blueprint are binding contracts; conflict requires a decision-record update before implementation.` --references--> `Approved 15-step greenfield build contract for a US-first bilingual CarrierFlow private pilot.`  [EXTRACTED]
  AGENTS.md → blueprints/carrierflow/blueprint.md
- `PRD and blueprint are binding contracts; conflict requires a decision-record update before implementation.` --references--> `CarrierFlow is a US/USD multi-tenant B2B private-invitation pilot for carriers, owners, dispatchers, and drivers; Canadian trips do not add Canadian commercial scope.`  [EXTRACTED]
  AGENTS.md → docs/product/carrierflow-prd.md
- `MVP excludes driver offers, payroll, ELD/load boards, truck-safe routing claims, pilot checkout, Canadian billing, and multi-region HA to keep operations safe and bounded.` --rationale_for--> `CarrierFlow is a US/USD multi-tenant B2B private-invitation pilot for carriers, owners, dispatchers, and drivers; Canadian trips do not add Canadian commercial scope.`  [EXTRACTED]
  blueprints/carrierflow/blueprint.md → docs/product/carrierflow-prd.md
- `Architect, Superpowers, Cyber Neo, UI UX Pro Max, and Graphify have distinct delivery ownership; Graphify is consulted before broad exploration and updated after durable changes.` --implements--> `CarrierFlow governance assigns architecture, disciplined implementation, security remediation, UX accessibility, and graph memory to named roles while allowing safe autonomous action.`  [EXTRACTED]
  AGENTS.md → blueprints/carrierflow/workspace/.codex/skills/carrierflow-governance/SKILL.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **The three epics form the ordered implementation sequence from governed tenant foundation to dispatch execution to pilot reliability and release evidence.** — blueprints_carrierflow_epics_01_foundation_tenant_audit_a11y, blueprints_carrierflow_epics_02_dispatch_operational_execution, blueprints_carrierflow_epics_03_reliability_pilot_release [EXTRACTED 1.00]
- **Pilot readiness combines self-hosted operational controls, reliability/release implementation, and cross-role physical, security, accessibility, and restore review.** — docs_architecture_adr_001_self_hosted_dokploy_pre_pilot_controls, blueprints_carrierflow_epics_03_reliability_pilot_release, docs_superpowers_specs_2026_08_27_carrierflow_design_pre_pilot_review_gates [EXTRACTED 1.00]
- **Tenant authorization, server-audited state/evidence enforcement, and durable offline idempotency jointly define a retry-safe trusted mutation boundary.** — agents_tenant_authorization_boundary, blueprints_carrierflow_blueprint_load_state_and_evidence_contract, docs_product_carrierflow_prd_privacy_offline_contract [INFERRED 0.95]

## Communities (34 total, 3 thin omitted)

### Community 0 - "compilerOptions"
Cohesion: 0.10
Nodes (20): compilerOptions, baseUrl, ignoreDeprecations, module, moduleResolution, noImplicitOverride, noUncheckedIndexedAccess, paths (+12 more)

### Community 1 - "fleet-service.ts"
Cohesion: 0.12
Nodes (33): assignDriverVehicle(), AssignDriverVehicleInput, authorizeManager(), createDriver(), CreateDriverInput, createVehicle(), CreateVehicleInput, databaseFailure() (+25 more)

### Community 2 - "devDependencies"
Cohesion: 0.18
Nodes (11): devDependencies, jsdom, @testing-library/react, @types/node, @types/react, @types/react-dom, jsdom, @testing-library/react (+3 more)

### Community 3 - "scripts"
Cohesion: 0.07
Nodes (27): devDependencies, @playwright/test, shadcn, supabase, tailwindcss, typescript, vitest, engines (+19 more)

### Community 4 - "scripts"
Cohesion: 0.07
Nodes (26): devDependencies, @playwright/test, shadcn, supabase, tailwindcss, typescript, vitest, engines (+18 more)

### Community 5 - "dependencies"
Cohesion: 0.07
Nodes (26): dependencies, maplibre-gl, next, react, react-dom, server-only, @supabase/ssr, @supabase/supabase-js (+18 more)

### Community 6 - "compilerOptions"
Cohesion: 0.12
Nodes (15): compilerOptions, incremental, jsx, plugins, resolveJsonModule, skipLibCheck, exclude, extends (+7 more)

### Community 7 - "All records and queries are organization-scoped with server-side authorization and database RLS; client filtering is never authorization."
Cohesion: 0.10
Nodes (21): Only authorized admin/dispatcher roles can assign, reassign, cancel, or close loads; drivers never receive those controls., Server-enforced auditable transitions, configurable evidence, consented GPS, durable offline idempotency, scoped public links, and bilingual accessible UX are inseparable product requirements., All records and queries are organization-scoped with server-side authorization and database RLS; client filtering is never authorization., Web and Flutter use validated server handlers/RPC; direct table mutations are prohibited and authorized mutations are transactional, RLS-protected, audited, and typed., Dokploy production Compose exposes only the TLS proxy and isolates application, self-hosted Supabase/data, and monitoring; backup restore, security, accessibility, device, and CI evidence gate pilot release., Administrative and operational load states are server-only; delivery requires pickup plus configured evidence, while incidents preserve the active load., Empty, loaded, total estimated miles, and quote per total mile are separately persisted; next-load deadhead begins at the active load's final planned stop and invalidations create immutable revisions and notifications., Flutter persists mutations before networking and represents denied, approximate, stale, and force-quit location states as degraded; background tracking is best effort for active loads. (+13 more)

### Community 8 - "write-audit.ts"
Cohesion: 0.14
Nodes (17): CompanyInvitation, createCompanyInvitation(), CreateCompanyInvitationInput, InvitationRpcArguments, InvitationRpcRow, RpcError, TrustedSupabaseServerClient, AdministrativePermission (+9 more)

### Community 9 - "compilerOptions"
Cohesion: 0.10
Nodes (19): compilerOptions, baseUrl, module, moduleResolution, noImplicitOverride, noUncheckedIndexedAccess, paths, strict (+11 more)

### Community 10 - "File and authority map"
Cohesion: 0.25
Nodes (7): CarrierFlow Pilot Build Implementation Plan, Coverage review, File and authority map, Task 1: Freeze the approved execution contract, Task 2: Bootstrap a dedicated implementation worktree, Task 3: Execute the 15-task DAG in three reviewable epics, Task 4: Certify the private-pilot gate

### Community 11 - "env.ts"
Cohesion: 0.48
Nodes (5): getSupabasePublicEnv(), requiredEnvironmentValue(), SupabasePublicEnv, validateSupabaseUrl(), createSupabaseServerClient()

### Community 12 - "Accepted decision: operate Dokploy on owner-controlled Ubuntu with Docker Compose and official Docker-based self-hosted Supabase for the private pilot."
Cohesion: 0.33
Nodes (6): Production is self-hosted Ubuntu/Dokploy/Compose with private networks, TLS proxy, backups, monitoring, rollback, and explicit single-host limits; no real pilot billing., Self-hosting minimizes recurring subscriptions while preserving data and operational control, but cheap infrastructure without recovery, isolation, or maintenance is unacceptable., ADR cites official Dokploy core/installation and Supabase self-hosting/Docker documentation as deployment references., Accepted decision: operate Dokploy on owner-controlled Ubuntu with Docker Compose and official Docker-based self-hosted Supabase for the private pilot., PRD cites official Dokploy, Supabase, platform location, FCM, MapLibre, routing, and future Stripe documentation., Dokploy/Compose self-hosting does not replace backups, restore tests, hardening, monitoring, capacity planning, or explicit single-server availability limits.

### Community 13 - "CarrierFlow is a US/USD multi-tenant B2B private-invitation pilot for carriers, owners, dispatchers, and drivers; Canadian trips do not add Canadian commercial scope."
Cohesion: 0.40
Nodes (5): PRD and blueprint are binding contracts; conflict requires a decision-record update before implementation., MVP excludes driver offers, payroll, ELD/load boards, truck-safe routing claims, pilot checkout, Canadian billing, and multi-region HA to keep operations safe and bounded., Approved 15-step greenfield build contract for a US-first bilingual CarrierFlow private pilot., Starter/Growth/Fleet active-driver capacity is enforced from the outset, but pilot entitlements expose trial/upgrade context without real charge or checkout until launch approval., CarrierFlow is a US/USD multi-tenant B2B private-invitation pilot for carriers, owners, dispatchers, and drivers; Canadian trips do not add Canadian commercial scope.

### Community 14 - "Q: How do mandatory assignment, mileage revisions, and tenant security constrain the private pilot?"
Cohesion: 0.40
Nodes (4): Answer, Outcome, Q: How do mandatory assignment, mileage revisions, and tenant security constrain the private pilot?, Source Nodes

### Community 15 - "Architect, Superpowers, Cyber Neo, UI UX Pro Max, and Graphify have distinct delivery ownership; Graphify is consulted before broad exploration and updated after durable changes."
Cohesion: 0.67
Nodes (3): Architect, Superpowers, Cyber Neo, UI UX Pro Max, and Graphify have distinct delivery ownership; Graphify is consulted before broad exploration and updated after durable changes., Five tracked project-scoped skills are required build artifacts; governance augments but never replaces them, and bootstrap is idempotent without overwriting existing artifacts., CarrierFlow governance assigns architecture, disciplined implementation, security remediation, UX accessibility, and graph memory to named roles while allowing safe autonomous action.

### Community 16 - "layout.tsx"
Cohesion: 0.14
Nodes (13): AdminLocale, AdminShell(), adminShellCss, AdminShellProps, CssVariables, messages, metadata, tokenizedBodyStyle (+5 more)

### Community 17 - "Private evidence needs authorized short-lived signed access, while public tracking is a load-scoped expiring/revocable minimal-data token with no session creation."
Cohesion: 0.67
Nodes (3): Private evidence needs authorized short-lived signed access, while public tracking is a load-scoped expiring/revocable minimal-data token with no session creation., HTTP/RPC inputs require typed safe errors; credentials stay out of clients/logs; public tokens are opaque, hashed, scoped, expiring, revocable, and rate-limited., Evidence is configurable and private; optional public tracking exposes only agreed single-load status/ETA/location through a revocable expiring opaque secret and excludes private documents and fleet data.

### Community 34 - "Design System Master File"
Cohesion: 0.11
Nodes (17): Additional Forbidden Patterns, Anti-Patterns (Do NOT Use), Buttons, Cards, Color Palette, Component Specs, Design System Master File, Global Rules (+9 more)

## Knowledge Gaps
- **169 isolated node(s):** `name`, `private`, `version`, `type`, `dev` (+164 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **3 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `devDependencies` connect `devDependencies` to `dependencies`?**
  _High betweenness centrality (0.006) - this node is a cross-community bridge._
- **What connects `name`, `private`, `version` to the rest of the system?**
  _169 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `compilerOptions` be split into smaller, more focused modules?**
  _Cohesion score 0.09523809523809523 - nodes in this community are weakly interconnected._
- **Should `fleet-service.ts` be split into smaller, more focused modules?**
  _Cohesion score 0.12380952380952381 - nodes in this community are weakly interconnected._
- **Should `scripts` be split into smaller, more focused modules?**
  _Cohesion score 0.07142857142857142 - nodes in this community are weakly interconnected._
- **Should `scripts` be split into smaller, more focused modules?**
  _Cohesion score 0.07407407407407407 - nodes in this community are weakly interconnected._
- **Should `dependencies` be split into smaller, more focused modules?**
  _Cohesion score 0.07407407407407407 - nodes in this community are weakly interconnected._