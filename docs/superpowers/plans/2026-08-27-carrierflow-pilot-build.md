# CarrierFlow Pilot Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` (recommended) or `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the approved CarrierFlow private pilot without changing its mandatory-assignment, tenant-safety, pricing-mileage, privacy, or self-hosted deployment contracts.

**Architecture:** The executable source of truth is the validated Architect bundle at `blueprints/carrierflow/`: `blueprint.md` defines the system and exact build order, `tasks.json` is the dependency DAG, and `epics/` contains each task’s standalone `DO`, acceptance and verification blocks. This plan governs how Superpowers executes that bundle; it does not duplicate implementation instructions that must remain byte-consistent across the bundle.

**Tech Stack:** pnpm/Node 24, Next.js/TypeScript/React, Flutter/Dart, self-hosted Supabase/PostgreSQL/PostGIS, Dokploy/Docker Compose, MapLibre, FCM, Drift, Vitest, Playwright and pgTAP.

---

## File and authority map

| Artifact | Responsibility |
|---|---|
| `blueprints/carrierflow/blueprint.md` | Product, architecture, exact bootstrap, technical pins, gates and release constraints |
| `blueprints/carrierflow/tasks.json` | Ordered 15-task DAG, dependencies, files, acceptance and verification |
| `blueprints/carrierflow/epics/*.md` | Self-contained task execution instructions for parallel/resumable work |
| `AGENTS.md` | Cross-cutting autonomy, security, UX, Graphify and product invariants |
| `docs/product/carrierflow-prd.md` | User-facing product contract and MVP acceptance rules |
| `docs/architecture/adr-001-self-hosted-dokploy.md` | Self-hosted production decision and pilot operational gates |

### Task 1: Freeze the approved execution contract

**Files:**

- Read: `AGENTS.md`, `docs/product/carrierflow-prd.md`, `blueprints/carrierflow/blueprint.md`, `blueprints/carrierflow/tasks.json`

- [ ] **Step 1: Confirm the build starts with a clean blueprint gate**

Run: `git show --stat --oneline c3f9df3`

Expected: the commit contains the tracked project skills, agent harness, product documents and `blueprints/carrierflow/` bundle.

- [ ] **Step 2: Select the first pending DAG task**

Run: `Get-Content blueprints/carrierflow/tasks.json | ConvertFrom-Json`

Expected: the only root task is the first workspace/foundation task; do not skip dependencies.

- [ ] **Step 3: Record the invariant baseline**

Confirm before writing code: drivers cannot accept/reject/reassign/cancel; all tenant data uses RLS; next-load deadhead begins at the current load’s final planned stop; background GPS is best effort; production remains self-hosted through Dokploy.

### Task 2: Bootstrap a dedicated implementation worktree

**Files:**

- Copy from: `blueprints/carrierflow/workspace/`
- Create: the product workspace files described by Blueprint §10

- [ ] **Step 1: Create an isolated worktree before implementation**

Run the `using-git-worktrees` skill and create a feature worktree from `codex/carrierflow-blueprint`.

Expected: implementation files are isolated while the approved blueprint remains unchanged.

- [ ] **Step 2: Execute Blueprint §10 exactly**

Run the PowerShell Bootstrap block in `blueprints/carrierflow/blueprint.md` from the new worktree.

Expected: it exits `0`, does not overwrite existing workspace/skill files, initializes local Git identity safely when necessary, and prepares pnpm/Supabase/Flutter tooling.

- [ ] **Step 3: Prove bootstrap idempotency**

Run the §20.1 Bootstrap re-run gate exactly as written.

Expected: second execution exits `0`; the workspace and all five project-scoped skill artifacts have unchanged hashes.

### Task 3: Execute the 15-task DAG in three reviewable epics

**Files:**

- Execute: `blueprints/carrierflow/epics/01-foundation.md`
- Execute: `blueprints/carrierflow/epics/02-dispatch.md`
- Execute: `blueprints/carrierflow/epics/03-reliability-release.md`

- [ ] **Step 1: Foundation (tasks 1–5)**

For each pending task in Epic 01: write the specified failing test, run its exact Verify command, implement only the epic’s `DO` block, rerun verification, update Graphify, commit and tag the prescribed checkpoint.

Expected: reproducible workspace, tenant/RLS/audit boundary, invitations/roles, bilingual accessible shell and eligible fleet/shift domain.

- [ ] **Step 2: Dispatch execution (tasks 6–10)**

Execute each standalone Epic 02 task in dependency order using TDD. Preserve separate empty/loaded/total mileage, immutable estimate revisions, mandatory assignment, configurable evidence, and current-load-first driver UX.

Expected: dispatch can quote/assign safely and drivers can execute only ordered authorized work.

- [ ] **Step 3: Reliability and pilot release (tasks 11–15)**

Execute each Epic 03 task in dependency order. Cyber Neo autonomously remediates scoped findings and records the result; UI UX Pro Max validates operational accessibility and EN/ES parity.

Expected: idempotent offline replay, honest location degradation, private/public data separation, pilot entitlements, Dokploy configuration and automated release gates.

### Task 4: Certify the private-pilot gate

**Files:**

- Verify: Blueprint §20.1–§20.4, `docs/architecture/adr-001-self-hosted-dokploy.md`

- [ ] **Step 1: Run the global automated gate**

Run every separate command in Blueprint §20.1.

Expected: typecheck, lint, tests, production build/start E2E, database tests, Compose validation and Bootstrap re-run evidence pass.

- [ ] **Step 2: Complete manual evidence—not substitutes**

Complete §20’s physical iOS/Android permission/GPS/push/offline checks, Cyber Neo report/remediation, UI UX audit, tested off-host restoration, Ubuntu hardening, monitoring and pilot invite controls.

Expected: the evidence is recorded; no claim is made that stores, background GPS after force-quit, or an external CI run passed without the actual external proof.

- [ ] **Step 3: Hand off and refresh memory**

Run Graphify update through the interpreter recorded at `graphify-out/.graphify_python`, report checks and residual risks, and use the `finishing-a-development-branch` skill before integration.

Expected: the graph, audit trail and release decision identify the exact implementation commit and manual gates.

## Coverage review

The validated bundle covers all PRD requirements: SaaS tenancy/plans, US/USD + Canada trips, roles/mandatory loads, stops/states/evidence, separate pricing miles, web/mobile/bilingual UX, offline/GPS/push, public links, security/RLS/auditing, Dokploy self-hosting and pilot/store gates. This plan intentionally delegates detailed code snippets and tests to the task `DO` blocks so one implementation contract is maintained across blueprint, DAG and epics.
