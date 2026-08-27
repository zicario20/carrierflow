# Epic 01 — Fundamentos multi-tenant

## Objetivo

Entregar workspace reproducible, auth/RLS, auditoría, shell bilingüe y flota.

## Contratos

- RLS deriva company desde membership
- cada mutación autorizada deja audit
- tokens/EN-ES son fuente única.

## Tareas

### E1-T1 — Inicializar monorepo y calidad base

**Dependencias:** ninguna  
**Prioridad:** p0  
**Archivos:** package.json, pnpm-workspace.yaml, apps/admin/package.json, apps/admin/src/app/page.tsx, tests/smoke/admin-http.spec.ts

**Dirección / DO**

Create the five listed root/admin/smoke files, including admin dev, build and start scripts. Run `pnpm add -Dw typescript@6.0.3 vitest@4.1.11 @playwright/test@1.62.1 supabase@2.116.0 tailwindcss@4.3.3 shadcn@4.19.0`, then `pnpm --filter @carrierflow/admin add next@16.3.3 react@19.2.8 react-dom@19.2.8 maplibre-gl@6.6.0` for the future operations map; create the HTTP smoke test before Verify.

**Aceptación**

1. WHEN pnpm install runs THE SYSTEM SHALL create a reproducible workspace lockfile and resolve the pinned Node/Next toolchain.
2. WHEN pnpm exec playwright test tests/smoke/admin-http.spec.ts runs THE SYSTEM SHALL start the admin application and receive HTTP 200 from its CarrierFlow home page.
3. WHEN pnpm --filter @carrierflow/admin typecheck runs THE SYSTEM SHALL exit 0 with strict TypeScript enabled.

**Verificar**

~~~bash
pnpm install
~~~
~~~bash
pnpm exec playwright install chromium
~~~
~~~bash
pnpm --filter @carrierflow/admin typecheck
~~~
~~~bash
pnpm --filter @carrierflow/admin build
~~~
~~~bash
pnpm exec playwright test tests/smoke/admin-http.spec.ts
~~~

**Checkpoint**

~~~bash
git add -A && git commit -m "E1-T1: Inicializar monorepo y calidad base"
git tag step-01-workspace
~~~

---

### E1-T2 — Crear tenant base, schema y RLS

**Dependencias:** E1-T1  
**Prioridad:** p0  
**Archivos:** supabase/migrations/0001_foundation.sql, supabase/tests/database/0001_foundation.sql, supabase/tests/database/helpers/tenant-fixtures.sql, apps/admin/src/lib/supabase/server.ts, apps/admin/src/lib/env.ts

**Dirección / DO**

Create the listed foundation migration, pgTAP database test/tenant fixture and server env/client files. Before importing them run `pnpm --filter @carrierflow/admin add @supabase/supabase-js@2.112.4 @supabase/ssr@0.12.5`; apply RLS and test it locally.

**Aceptación**

1. WHEN the foundation migration is applied to a local Supabase database THE SYSTEM SHALL create companies, memberships, roles, audit events and RLS policies.
2. WHEN a member queries a company-scoped row THE SYSTEM SHALL return only rows in that member’s company.
3. WHEN an unauthenticated or cross-company query is attempted THE SYSTEM SHALL return zero protected rows.

**Verificar**

~~~bash
pnpm exec supabase db reset
~~~
~~~bash
pnpm exec supabase test db
~~~
~~~bash
pnpm --filter @carrierflow/admin typecheck
~~~

**Checkpoint**

~~~bash
git add -A && git commit -m "E1-T2: Crear tenant base, schema y RLS"
git tag step-02-tenant-foundation
~~~

---

### E1-T3 — Implementar invitaciones, roles y auditoría

**Dependencias:** E1-T2  
**Prioridad:** p0  
**Archivos:** supabase/migrations/0002_identity_and_roles.sql, supabase/tests/database/0002_identity_and_roles.sql, apps/admin/src/server/auth/authorize.ts, apps/admin/src/server/result.ts, apps/admin/src/server/audit/write-audit.ts

**Dirección / DO**

Create the listed identity migration, pgTAP role test, authorize/result/audit modules. Implement invitation, typed forbidden result and same-transaction audit, then author unit coverage inside the admin test suite.

**Aceptación**

1. WHEN an owner creates an invitation THE SYSTEM SHALL create a pending membership scoped to that owner’s company.
2. WHEN a driver invokes an administrative mutation THE SYSTEM SHALL return a typed forbidden result and write no business change.
3. WHEN an authorized mutation succeeds THE SYSTEM SHALL write actor, timestamp, before and after values to the audit log.

**Verificar**

~~~bash
pnpm exec supabase db reset
~~~
~~~bash
pnpm exec supabase test db
~~~
~~~bash
pnpm --filter @carrierflow/admin test
~~~

**Checkpoint**

~~~bash
git add -A && git commit -m "E1-T3: Implementar invitaciones, roles y auditoría"
git tag step-03-roles-audit
~~~

---

### E1-T4 — Construir shell administrativo bilingüe

**Dependencias:** E1-T1  
**Prioridad:** p0  
**Archivos:** packages/design-tokens/src/tokens.ts, apps/admin/src/app/layout.tsx, apps/admin/src/i18n/en.json, apps/admin/src/i18n/es.json, apps/admin/tests/ui/shell-a11y.test.tsx

**Dirección / DO**

Create the five listed token, layout, en/es and accessibility-test files. Define the operational light-first tokens, translate navigation/state labels, render a labelled main landmark and test 44 px/non-color contract.

**Aceptación**

1. WHEN the locale is en or es THE SYSTEM SHALL render the navigation and operational labels in that locale without missing keys.
2. WHEN the shell is rendered by the accessibility test THE SYSTEM SHALL expose a labelled main landmark and no color-only status control.
3. WHEN a control is interactive THE SYSTEM SHALL use the shared token set and a 44 px minimum target contract.

**Verificar**

~~~bash
pnpm --filter @carrierflow/admin test tests/ui/shell-a11y.test.tsx
~~~
~~~bash
pnpm --filter @carrierflow/admin lint
~~~
~~~bash
pnpm --filter @carrierflow/admin typecheck
~~~

**Checkpoint**

~~~bash
git add -A && git commit -m "E1-T4: Construir shell administrativo bilingüe"
git tag step-04-admin-shell
~~~

---

### E1-T5 — Añadir conductor, vehículo y turno

**Dependencias:** E1-T2, E1-T3  
**Prioridad:** p0  
**Archivos:** supabase/migrations/0003_fleet.sql, supabase/tests/database/0003_fleet.sql, apps/admin/src/server/fleet/fleet-service.ts, apps/admin/src/app/(ops)/fleet/page.tsx, apps/admin/tests/fleet-service.test.ts

**Dirección / DO**

Create the listed fleet migration, pgTAP test, fleet service, fleet page and test. Add driver/vehicle CRUD, shift audit, and server validation that rejects inactive assignment.

**Aceptación**

1. WHEN dispatcher creates a driver or vehicle THE SYSTEM SHALL persist it only within the dispatcher’s company.
2. WHEN a driver starts or ends a shift THE SYSTEM SHALL record on_duty or off_duty with an audit event.
3. WHEN an inactive driver or vehicle is selected for assignment THE SYSTEM SHALL reject the operation with a typed validation error.

**Verificar**

~~~bash
pnpm exec supabase db reset
~~~
~~~bash
pnpm exec supabase test db
~~~
~~~bash
pnpm --filter @carrierflow/admin test tests/fleet-service.test.ts
~~~

**Checkpoint**

~~~bash
git add -A && git commit -m "E1-T5: Añadir conductor, vehículo y turno"
git tag step-05-fleet-shifts
~~~


---

## Aceptación del epic

1. WHEN all tasks in this epic are complete THE SYSTEM SHALL satisfy every task acceptance criterion through its declared local verification.
2. WHEN an invalid, unauthorized or degraded path is exercised THE SYSTEM SHALL preserve tenant isolation, ordered load state and a typed recoverable response.

## Pitfalls

- No service role cliente
- no editar migration aplicada
- autorización no vive solo en UI.

## Antes de avanzar

- [ ] Cada task es done en tasks.json después de verify.
- [ ] Cada checkpoint coincide literalmente con tasks.json.
- [ ] No se modificó una migration aplicada ni se introdujo secreto.
- [ ] Cambios de código/documentación se registraron en Graphify cuando esté disponible.

