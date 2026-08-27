# CarrierFlow — Agent Harness

CarrierFlow is a US-first, multi-tenant B2B SaaS for carrier owners, dispatchers, and drivers. Its product contract is defined in [`docs/product/carrierflow-prd.md`](docs/product/carrierflow-prd.md) and its implementation contract in [`blueprints/carrierflow/blueprint.md`](blueprints/carrierflow/blueprint.md). If they disagree, stop and update the decision record before continuing.

## Authority and autonomy

Every agent is autonomous within its role: it may inspect, decide, implement, test, and document work necessary to complete its assigned outcome. It must leave the repository more verifiable than it found it: run relevant checks, record material decisions, and report what changed and what was verified.

Escalate only when the action is irreversible or outside repository/product scope: deleting material user data, rotating or using real production credentials, changing billing or a paid external service, publishing, contacting third parties, or changing a confirmed product rule.

1. **The Architect is the project head.** It owns requirements interpretation, architecture, boundaries, data contracts, milestones, and blueprint consistency. Do not begin a feature without consulting the current blueprint and decision records.
2. **Superpowers is the delivery engineer.** It owns disciplined implementation: discovery before behavior changes, small plans, test-driven work, systematic debugging, code review, verification, and clean handoff.
3. **Cyber Neo is the security owner.** It may autonomously remediate scoped security defects in this repository, add tests or hardening, and notify the team with the finding, fix, verification, residual risk, and affected files. It does not exfiltrate secrets, use real credentials, alter external systems, or make destructive changes without escalation.
4. **UI UX Pro Max is the product-design owner.** It may autonomously create or revise interface specifications, tokens, flows, components, copy, accessibility criteria, and visual validation. Its decisions preserve the approved operational design system and bilingual usability.
5. **Graphify is the project memory.** It maintains the local knowledge graph and is consulted before broad codebase exploration once a graph exists.

The user’s confirmed product rules and safety requirements outrank agent preferences. The root harness applies to every directory unless a deeper `AGENTS.md` states a stricter rule.

## Required operating sequence

1. Read this file, the relevant product/blueprint documents, and any closer `AGENTS.md`.
2. Query Graphify memory when it exists; inspect scoped files before making assumptions.
3. The Architect resolves material architecture. Superpowers plans and tests implementation. UI UX Pro Max validates user-facing work. Cyber Neo performs security work and remediation before pilot/release gates.
4. Implement only the smallest coherent slice. Keep tenant isolation, auditability, offline safety, bilingual strings, and accessibility in the same slice—not as deferred cleanup.
5. Run prescribed checks. If a test or gate fails, use systematic debugging; do not mask failures.
6. Update Graphify after code or durable documentation changes, then report decisions, files, checks, and remaining manual gates.

Current repository state: this is an architecture-and-blueprint workspace. Do not invent application commands before the blueprint’s bootstrap step creates them.

## Non-negotiable CarrierFlow rules

- The product is a US-first multi-tenant SaaS. A load may cross into Canada, but MVP billing, currency, legal posture, and primary market are US/USD.
- Every record and query is organization-scoped. Tenant isolation is enforced server-side and in database RLS; a client-side filter is never authorization.
- Roles are `owner`, `admin`, `dispatcher`, and `driver`. Drivers see only their own permitted data.
- Assignment is mandatory. Drivers never receive accept/reject, reassignment, cancellation, or cross-driver controls. Only authorized admin/dispatcher roles can assign, reassign, cancel, or close a load.
- Operational state transitions are server-enforced and auditable. A load cannot be delivered before pickup; an incident does not silently cancel an active load.
- A quote/proposal is an internal dispatcher pricing workflow, not a driver offer. Display empty/deadhead miles, loaded miles, total estimated miles, and quote per total mile separately. For a next load, deadhead begins at the final planned stop of the active load—not live GPS. Route-estimate revisions are versioned and auditable.
- Driver-visible compensation/rate is explicitly authorized by dispatch. Broker/customer revenue, margins, and internal financial fields are admin-only. CarrierFlow does not implement payroll in the MVP.
- Evidence requirements are configurable per customer/load. Photos are optional where facilities prohibit phones; signature/name and BOL/POD requirements are independently configurable.
- GPS collection is conspicuous, consented to, minimized, and resilient. Background tracking for an active load is best effort within iOS/Android permissions and OS limits—never promise tracking after force-quit or permission revocation. Separate current location from retained history and expose stale/permission states.
- Offline mutations require durable outbox records and idempotency keys; never create duplicate delivery, evidence, or status events after reconnecting.
- Customer/broker tracking links are opaque, load-scoped, revocable, expiring, and never expose private documents or unrelated fleet data.
- The experience is bilingual English/Spanish, operational and accessible: light-first, clear states beyond color, WCAG contrast, touch targets of at least 44px, and reduced motion support.

## Architecture and deployment guardrails

- Use the approved Next.js/TypeScript admin web app, Flutter driver app, PostgreSQL/Supabase data plane, private realtime delivery, FCM notifications, MapLibre visualization, and a replaceable routing-provider adapter. MapLibre is not a routing engine.
- Production is self-hosted first: deploy on the owner’s Ubuntu server through Dokploy and Docker Compose. Do not presume a recurring managed cloud platform. Use separate private networks, TLS/domains through the deployment proxy, non-versioned secrets, persistent volumes, tested backup/restore, versioned upgrades/rollback, monitoring, and OS hardening gates.
- A single Ubuntu server is not high availability or disaster recovery. Any pilot production deployment must state capacity limits, restoration target, off-server encrypted backup location, and operator runbook. Self-hosted Supabase/Postgres is an operations responsibility, not a free managed service.
- Keep privileged Supabase/service credentials server-only. Validate authorization, tenant scope, state transitions, idempotency, and evidence requirements in trusted server/database operations.
- Store private evidence behind authenticated, scoped access. Do not place keys, signed URLs with excessive lifetime, driver locations, or personal data in public links or client logs.
- Do not treat a connectivity signal as successful synchronization. Network operations confirm success only from the server response and preserve retry-safe state.
- No real subscription charge during the private pilot. Build plan entitlements and usage limits now; enable hosted web billing only after the explicit store-approval gate.
- Navigation may open Google Maps or Apple Maps. Do not represent general routing as truck-safe or legal for commercial vehicles without separately validated data and capability.

## Quality gates

### Before merging any product change

- Superpowers: focused tests first or alongside the change; lint, types, and relevant unit/integration tests pass.
- UI UX Pro Max: operational flow, responsive states, keyboard/touch access, screen-reader labels, English/Spanish copy, contrast, loading/error/empty states reviewed.
- Cyber Neo: authorization/RLS, input validation, secret exposure, dependency, storage, public-link, and privacy implications reviewed; scoped findings are fixed or an explicit accepted risk is recorded.
- The Architect: dependency/order/data-contract impact matches the current blueprint or its decision log is updated.
- Graphify: durable changes are reflected with `graphify update .` after checks pass.

### Before private-pilot, store, or public release

- Run the Cyber Neo full security audit and remediate release-blocking findings.
- Verify RLS and cross-tenant denial, state-machine ordering, idempotent offline replay, evidence enforcement, public-link expiry/revocation, and plan driver-capacity limits.
- Perform physical Android and iOS checks for background location, permissions, notifications, offline recovery, uploads, external navigation, and bilingual UX.
- Verify privacy disclosures, retention behavior, support/reviewer test accounts, monitoring, rollback, Dokploy deployment, off-server restoration, and pilot invitation controls.

## Graphify memory

This project has a knowledge graph at `graphify-out/` with god nodes, community structure, and cross-file relationships.

When the user types `/graphify`, use the installed Graphify skill or instructions before doing anything else.

- For codebase questions, first run the Graphify command through its recorded interpreter when `graphify-out/graph.json` exists: `& (Get-Content graphify-out/.graphify_python) -m graphify query "<question>"`. Use its `path` and `explain` subcommands for relationships and focused concepts.
- If `graphify-out/wiki/index.md` exists, use it for broad navigation instead of raw source browsing. Read `graphify-out/GRAPH_REPORT.md` only for broad architecture review or when scoped queries are insufficient.
- After modifying code or durable documentation, run `& (Get-Content graphify-out/.graphify_python) -m graphify update .` to keep the graph current. If that interpreter marker is absent, initialize Graphify through its installed skill first. Keep generated vendor skills, dependencies, and build output excluded from graph input.
- Dirty `graphify-out/` files are expected after hooks or incremental updates; do not treat them as unrelated changes to discard.

## Reporting format

End each completed task with: outcome; decisions made; files changed; verification performed; security/privacy impact; Graphify update status; and any manual gate or accepted risk. Cyber Neo reports additionally include severity, remediation, and residual risk.
