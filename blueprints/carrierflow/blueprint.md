# CarrierFlow — Blueprint de construcción

Estado: aprobado para construcción. Idioma de producto: en-US y es-US. Bundle resumible: 15 pasos exactamente.

## 1. Project Overview & Non-Goals

CarrierFlow es un SaaS B2B multi-tenant de EE. UU. para carrier owners, admins, dispatchers y conductores. Next.js administra compañías, cargas, flota, telemetría y evidencia; Flutter guía al conductor Android/iOS. El piloto es privado/invitación única y no cobra antes de aprobación de Apple/Google. Planes futuros: Starter USD 20/10 drivers, Growth USD 40/25, Fleet USD 60/60. Entitlements/capacity existen desde el inicio sin checkout. EE. UU. es centro comercial/USD/billing; una carga puede cruzar Canadá sin introducir billing, tax o compliance canadiense.

| Non-goal | Razón | Trigger para reconsiderarlo |
|---|---|---|
| Driver acepta/rechaza | Asignación obligatoria. | Cambio explícito de política operacional. |
| Nómina/pagos driver | Precio/milla es guía, no payroll. | Modelo financiero y legal aprobado. |
| ELD/load boards/optimización | Alto alcance e integración. | Operación MVP validada y presupuesto. |
| Ruteo seguro semitruck | Google/Apple externos no garantizan restricción pesada. | Proveedor comercial/revisión legal. |
| Stripe/checkouts piloto | Piloto privado hasta stores. | Aprobación Apple/Google y plan de billing. |
| HA multi-región | Un Ubuntu no ofrece HA. | RTO/RPO, crecimiento y presupuesto. |
| Billing/impuestos Canadá | Mercado central EE. UU. | Lanzamiento canadiense explícito. |

## 2. Tech Stack

| Área | Decisión | Razón |
|---|---|---|
| Repo | pnpm workspace, apps/admin, apps/driver, packages, supabase | contratos coherentes y límites claros. |
| Web | Next 16.3.3, React 19.2.8, TS 6.0.3, Tailwind 4.3.3, shadcn 4.19.0 | panel server-first. |
| Móvil | Flutter 3.47.2/Dart 3.13.2 | Android/iOS con GPS nativo. |
| Datos/auth | Supabase self-host: Postgres 17+, PostGIS, Auth, Storage, RLS, Realtime | aislamiento y menor suscripción. |
| Mapas | MapLibre GL JS 6.6.0 y RoutingProvider Google Routes/OSRM futuro | mapa visual no se confunde con routing. |
| Offline/push | Drift SQLite, FCM/APNs | outbox durable y push. |
| Deploy | Ubuntu 24.04 + Dokploy + Docker Compose + Traefik | self-hosted versionado; no HA. |
| Billing futuro | Stripe web + webhook durable | después del piloto/stores. |

No se usan segunda identidad/migración/API, service role cliente, realtime en memoria ni CSS-in-JS runtime.

## 3. Directory Structure

~~~
apps/admin/               Next dashboard
apps/driver/              Flutter
packages/contracts/       schemas/contratos
packages/design-tokens/   tokens/paridad Flutter
packages/routing-contract/ RoutingProvider
supabase/migrations/      schema/RLS único
supabase/tests/database/  pgTAP/fixtures
infra/dokploy/            deploy sin secretos
tests/                    Playwright/security/a11y
blueprints/carrierflow/   bundle excluido de tooling
.codex/                   agent instructions
~~~

## 4. Data Model

Cada fila comercial lleva company_id/RLS/auditoría. Entidades: companies, company_memberships, roles; drivers, vehicles, shifts; loads, load_stops, load_assignments; load_status_events, incidents, audit_events; route_estimate_revisions; evidence_requirements/items; driver_locations_current/events; devices, notifications, sync_operations; public_tracking_links; subscription_entitlements/billing_events.

Stops son ordenados: UI piloto crea 1 pickup + 1 delivery, modelo soporta varios. Índices: company_id/id, carga activa por driver, load_id/sequence, company/driver/recorded_at y token hash único. current location mutable se separa de histórico/retención.

## 5. API Design

No hay mutation directa de tablas. Admin/Flutter llaman route handlers/RPC con validación, membership, company y audit.

| Operación | Actor | Garantía |
|---|---|---|
| create/assign/reassign/cancel/transition | dispatcher/admin | transacción, RLS, audit, resultado tipado. |
| recalculate estimate | dispatcher/service | snapshot, revisión inmutable/notification. |
| shift/location/sync | driver propio | client_mutation_id exactamente una vez. |
| evidence storage | actor autorizado | ruta privada, tipo/tamaño, URL firmada corta. |
| public track token | sin sesión | scope carga/expiry/revoke, datos mínimos. |
| billing webhook futuro | Stripe servidor | firma/idempotencia; no redirect grant. |

Estados server-only: administrative draft/scheduled/cancelled/closed; operational assigned/to_pickup/at_pickup/loading/picked_up/to_delivery/at_delivery/unloading/delivered. delivered exige picked_up + evidencia configurada; incidente no cancela. Persistir/display por separado empty_miles, loaded_miles, total_estimated_miles y quote_usd/total. Si existe carga activa, deadhead de siguiente sale del final planificado, nunca GPS. Driver ve rate autorizado; margen/revenue es admin-only.

## 6. Frontend Architecture

Admin routes en apps/admin/app/(ops); page server-first → service/RPC → Supabase. Client components solo interacción/mapa; no importan DB/service role. MapLibre muestra current locations filtradas, disclaimer y botones externos Google/Apple; tiles tienen URL/coste explícito.

Flutter: main → auth gate → load home → current detail/state/evidence; next load visible sin bloquear actual. Drift persiste mutación/adjunto antes de red. Core Location/Fused Location/Android location FGS hacen background de carga activa; workmanager solo recovery. denied/approximate/stale/force-quit se muestran como degradado. Playwright tiene webServer y HTTP smoke desde Paso 1.

## 7. Design System

| Token | Valor |
|---|---|
| Fondo/superficie/texto | #F8FAFC / #FFFFFF / #0F172A |
| Primario/éxito/alerta/error | #0F6CBD / #067647 / #B54708 / #B42318 |
| Borde/muted | #CBD5E1 / #475569 |
| Dark | #0F172A / #172033 |
| Tipo | Inter; JetBrains Mono o IBM Plex Mono cifras |
| Escala | 12/14/16/20/24/32, base 4 |
| Interacción | 44 px, radio 8/12, 150–200 ms/reduce motion |

Diseño light-first, profesional operacional, no HUD. Estado siempre texto/icono/color; EN/ES, foco, teclado, landmarks, loading/error/retry y alternativa textual a mapa/tablas.

## 8. Authentication & Authorization

Supabase Auth es sesión única. Membership une user_id/company_id/role; RLS protege y service/RPC vuelve a autorizar. Driver solo perfil, vehículo, cargas/evidencia/incidentes propios. Owner/admin/dispatcher administran de acuerdo con permiso. service role existe solo servidor. Public tracking no enumera ID ni crea sesión; Storage privada exige URL firmada tras autorización.

## 9. BUILD ORDER

### 9.1 Parity and cutover

NOT APPLICABLE — greenfield build, no system is being replaced.

### Paso 1 — Inicializar monorepo y calidad base

Archivos: package.json, pnpm-workspace.yaml, apps/admin/package.json, apps/admin/src/app/page.tsx, tests/smoke/admin-http.spec.ts.

**DO**

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

**Checkpoint:** step-01-workspace.

### Paso 2 — Crear tenant base, schema y RLS

Archivos: supabase/migrations/0001_foundation.sql, supabase/tests/database/0001_foundation.sql, supabase/tests/database/helpers/tenant-fixtures.sql, apps/admin/src/lib/supabase/server.ts, apps/admin/src/lib/env.ts.

**DO**

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

**Checkpoint:** step-02-tenant-foundation.

### Paso 3 — Implementar invitaciones, roles y auditoría

Archivos: supabase/migrations/0002_identity_and_roles.sql, supabase/tests/database/0002_identity_and_roles.sql, apps/admin/src/server/auth/authorize.ts, apps/admin/src/server/result.ts, apps/admin/src/server/audit/write-audit.ts.

**DO**

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

**Checkpoint:** step-03-roles-audit.

### Paso 4 — Construir shell administrativo bilingüe

Archivos: packages/design-tokens/src/tokens.ts, apps/admin/src/app/layout.tsx, apps/admin/src/i18n/en.json, apps/admin/src/i18n/es.json, apps/admin/tests/ui/shell-a11y.test.tsx.

**DO**

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

**Checkpoint:** step-04-admin-shell.

### Paso 5 — Añadir conductor, vehículo y turno

Archivos: supabase/migrations/0003_fleet.sql, supabase/tests/database/0003_fleet.sql, apps/admin/src/server/fleet/fleet-service.ts, apps/admin/src/app/(ops)/fleet/page.tsx, apps/admin/tests/fleet-service.test.ts.

**DO**

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

**Checkpoint:** step-05-fleet-shifts.

### Paso 6 — Modelar cargas, evidencia y estados

Archivos: supabase/migrations/0004_loads.sql, supabase/tests/database/0004_loads.sql, apps/admin/src/server/loads/load-service.ts, apps/admin/src/server/loads/load-state-machine.test.ts, apps/admin/src/app/(ops)/loads/[loadId]/page.tsx.

**DO**

Create the listed load migration, pgTAP test, load service, state-machine test and load detail page. Model ordered stops/evidence/incidents, enforce transition order in server and show the read-only load detail.

**Aceptación**

1. WHEN a load is created THE SYSTEM SHALL store ordered pickup/delivery stops while allowing the pilot form to create exactly one of each.
2. WHEN an actor attempts delivered before picked_up THE SYSTEM SHALL reject the transition and retain the prior state.
3. WHEN evidence requirements are configured THE SYSTEM SHALL block delivery until each required non-photo item has valid evidence.
4. WHEN a problem is reported THE SYSTEM SHALL create an incident without cancelling or bypassing the active load state.

**Verificar**

~~~bash
pnpm exec supabase db reset
~~~
~~~bash
pnpm exec supabase test db
~~~
~~~bash
pnpm --filter @carrierflow/admin test src/server/loads/load-state-machine.test.ts
~~~

**Checkpoint:** step-06-load-domain.

### Paso 7 — Calcular millas y revisiones de tarifa

Archivos: supabase/migrations/0005_route_estimates.sql, apps/admin/src/server/routing/routing-provider.ts, apps/admin/src/server/routing/estimate-service.ts, apps/admin/src/server/routing/estimate-service.test.ts, packages/routing-contract/src/index.ts.

**DO**

Create the listed route-estimate migration, provider interface, service, unit test and routing contract. Persist empty/loaded/total/rate revisions and invalidate/recalculate from active final stop.

**Aceptación**

1. WHEN a proposed load has a quoted amount and route THE SYSTEM SHALL persist empty miles, loaded miles, total miles and quote_usd divided by total_miles as separate values.
2. WHEN a driver has an active load THE SYSTEM SHALL calculate the next load’s empty miles from the final planned active stop, not current GPS.
3. WHEN final stop, driver or assignment changes THE SYSTEM SHALL invalidate the previous estimate, persist a new immutable revision and create a dispatcher notification.

**Verificar**

~~~bash
pnpm --filter @carrierflow/admin test src/server/routing/estimate-service.test.ts
~~~
~~~bash
pnpm --filter @carrierflow/admin typecheck
~~~

**Checkpoint:** step-07-routing-pricing.

### Paso 8 — Crear flujo web de propuesta y asignación

Archivos: apps/admin/src/app/(ops)/loads/new/page.tsx, apps/admin/src/components/loads/load-form.tsx, apps/admin/src/components/loads/mileage-breakdown.tsx, apps/admin/tests/load-dispatch-flow.spec.ts, apps/admin/src/app/(ops)/map/page.tsx.

**DO**

Create the listed proposal form, mileage breakdown, dispatch test and operations map page. The map page uses the MapLibre dependency provisioned in Paso 1, shows authorised current location/text fallback, and does not expose raw history; the form exposes no accept/reject control.

**Aceptación**

1. WHEN dispatcher enters quote and stops THE SYSTEM SHALL show empty, loaded and total miles separately plus the quoted dollars per total mile.
2. WHEN dispatcher assigns a load THE SYSTEM SHALL show the assignment as mandatory and expose no driver acceptance or rejection control.
3. WHEN dispatcher reassigns or cancels a load THE SYSTEM SHALL require authority, retain the event history and refresh the assignee-facing state.
4. WHEN the operations map route is opened THE SYSTEM SHALL render the authorised current-location surface and a textual fallback without accessing historical locations.

**Verificar**

~~~bash
pnpm --filter @carrierflow/admin test tests/load-dispatch-flow.spec.ts
~~~
~~~bash
pnpm --filter @carrierflow/admin typecheck
~~~
~~~bash
pnpm --filter @carrierflow/admin lint
~~~

**Checkpoint:** step-08-dispatch-ui.

### Paso 9 — Inicializar Flutter y lista actual/siguiente

Archivos: apps/driver/pubspec.yaml, apps/driver/lib/main.dart, apps/driver/lib/features/auth/auth_gate.dart, apps/driver/lib/features/loads/load_home_page.dart, apps/driver/test/load_home_page_test.dart.

**DO**

Create the listed Flutter pubspec, main, auth gate, load home and widget test. Before any Flutter package usage run each literal command: `cd apps/driver && flutter pub add supabase_flutter:2.17.2`; `cd apps/driver && flutter pub add firebase_core:4.14.0`; `cd apps/driver && flutter pub add firebase_messaging:16.6.0`; `cd apps/driver && flutter pub add drift:2.34.3`; `cd apps/driver && flutter pub add drift_flutter:0.3.1`; `cd apps/driver && flutter pub add connectivity_plus:7.3.1`; `cd apps/driver && flutter pub add url_launcher:6.3.2`; `cd apps/driver && flutter pub add geolocator:14.0.3`; `cd apps/driver && flutter pub add workmanager:0.10.9`; `cd apps/driver && flutter pub add maplibre_gl:0.27.0`. Then show current then next load and localized empty state.

**Aceptación**

1. WHEN a driver with a valid session opens the app THE SYSTEM SHALL show the current load prominently and a next assigned load without blocking the current workflow.
2. WHEN the app locale is English or Spanish THE SYSTEM SHALL render driver-facing load labels from locale resources.
3. WHEN no load is assigned THE SYSTEM SHALL show a safe empty state rather than another driver’s data.

**Verificar**

~~~bash
cd apps/driver && flutter pub get
~~~
~~~bash
cd apps/driver && flutter test test/load_home_page_test.dart
~~~
~~~bash
cd apps/driver && flutter analyze
~~~

**Checkpoint:** step-09-driver-shell.

### Paso 10 — Ejecutar carga y evidencia en móvil

Archivos: apps/driver/lib/features/loads/load_detail_page.dart, apps/driver/lib/features/loads/load_state_controller.dart, apps/driver/lib/features/evidence/evidence_capture.dart, apps/driver/test/load_state_controller_test.dart, apps/driver/test/evidence_requirements_test.dart.

**DO**

Create the listed Flutter detail/state/evidence files and tests. Call server-defined transitions only, check configurable evidence before delivery and enqueue incident information without cancelling a load.

**Aceptación**

1. WHEN a driver advances a load THE SYSTEM SHALL allow only the server-defined ordered transitions.
2. WHEN configured evidence is incomplete THE SYSTEM SHALL disable delivery and identify the missing required evidence without making photos universally required.
3. WHEN a driver reports an incident THE SYSTEM SHALL send its category, text, location when available and attachments without cancelling the load.

**Verificar**

~~~bash
cd apps/driver && flutter test test/load_state_controller_test.dart
~~~
~~~bash
cd apps/driver && flutter test test/evidence_requirements_test.dart
~~~
~~~bash
cd apps/driver && flutter analyze
~~~

**Checkpoint:** step-10-driver-execution.

### Paso 11 — Añadir outbox offline e idempotencia

Archivos: supabase/migrations/0006_sync_operations.sql, apps/driver/lib/core/sync/outbox.dart, apps/driver/lib/core/sync/sync_worker.dart, apps/driver/test/outbox_test.dart, apps/admin/src/server/sync/idempotency-service.test.ts.

**DO**

Create the sync migration, outbox, worker and listed Flutter/admin tests. Persist client_mutation_id before send, replay exactly once, preserve dependency ordering and expose retry.

**Aceptación**

1. WHEN network is unavailable THE SYSTEM SHALL queue state/evidence mutations locally with a unique client mutation ID.
2. WHEN the same mutation is replayed after reconnecting THE SYSTEM SHALL return the original server result and create no second delivery or evidence item.
3. WHEN synchronization fails transiently THE SYSTEM SHALL retain the item, expose retry state and preserve order where dependency requires it.

**Verificar**

~~~bash
pnpm exec supabase db reset
~~~
~~~bash
cd apps/driver && flutter test test/outbox_test.dart
~~~
~~~bash
pnpm --filter @carrierflow/admin test src/server/sync/idempotency-service.test.ts
~~~

**Checkpoint:** step-11-offline-sync.

### Paso 12 — Seguimiento, mapa y permisos degradados

Archivos: supabase/migrations/0007_locations.sql, apps/driver/lib/features/tracking/tracking_service.dart, apps/driver/lib/features/tracking/tracking_permission_state.dart, apps/driver/test/tracking_service_test.dart, apps/driver/android/app/src/main/AndroidManifest.xml.

**DO**

Create the five listed location migration, tracking service/permission state/test and Android manifest. Use MapLibre packages already provisioned by Pasos 1 and 9; write current/history/retention data that the existing Paso 8 map surface reads, and model denied/approximate/stale/background states without force-quit promises.

**Aceptación**

1. WHEN an on-duty driver is visible or logged in with an active load THE SYSTEM SHALL record adaptive location samples and show their freshness/accuracy state.
2. WHEN a load is active and the interface is closed THE SYSTEM SHALL request platform-appropriate background tracking, while showing revoked, approximate or unavailable permission as degraded state.
3. WHEN the map loads THE SYSTEM SHALL display last authorized current location and load context without streaming unrestricted history.
4. WHEN a location is retained past policy THE SYSTEM SHALL roll it up or purge it according to the company retention job.

**Verificar**

~~~bash
pnpm exec supabase db reset
~~~
~~~bash
cd apps/driver && flutter test test/tracking_service_test.dart
~~~
~~~bash
pnpm --filter @carrierflow/admin test
~~~

**Checkpoint:** step-12-tracking-map.

### Paso 13 — Notificar y compartir tracking limitado

Archivos: supabase/migrations/0008_notifications_public_links.sql, apps/admin/src/server/notifications/notification-service.ts, apps/admin/src/app/api/public/track/[token]/route.ts, apps/driver/lib/core/push/push_service.dart, apps/admin/tests/public-tracking-link.test.ts.

**DO**

Create the listed notification/public-link migration, server service, public route, Flutter push service and test. Send minimal ID payloads and return only scoped/expiring/revocable tracking data.

**Aceptación**

1. WHEN a load is assigned, reassigned, changed or cancelled THE SYSTEM SHALL create a minimal notification addressed to the affected device.
2. WHEN a valid public tracking token is used THE SYSTEM SHALL return only the allowed load status, ETA and configured location data for that single load.
3. WHEN a public token is expired or revoked THE SYSTEM SHALL return no load data and an HTTP 404 response.

**Verificar**

~~~bash
pnpm exec supabase db reset
~~~
~~~bash
pnpm --filter @carrierflow/admin test tests/public-tracking-link.test.ts
~~~
~~~bash
cd apps/driver && flutter analyze
~~~

**Checkpoint:** step-13-notifications-tracking.

### Paso 14 — Aplicar entitlements y retención piloto

Archivos: supabase/migrations/0009_entitlements_retention.sql, apps/admin/src/server/billing/entitlement-service.ts, apps/admin/src/server/privacy/retention-service.ts, apps/admin/src/app/(ops)/settings/plan/page.tsx, apps/admin/tests/entitlement-service.test.ts.

**DO**

Create the listed entitlement/retention migration, services, plan page and test. Enforce pilot capacity, show trial without checkout and record privacy retention action.

**Aceptación**

1. WHEN a company attempts to activate a driver above its pilot plan capacity THE SYSTEM SHALL reject activation without modifying existing drivers.
2. WHEN a company is in private pilot THE SYSTEM SHALL expose plan capacity and trial state without initiating a payment or checkout request.
3. WHEN retention jobs run THE SYSTEM SHALL record the policy action and preserve only permitted location/evidence metadata.

**Verificar**

~~~bash
pnpm exec supabase db reset
~~~
~~~bash
pnpm --filter @carrierflow/admin test tests/entitlement-service.test.ts
~~~
~~~bash
pnpm --filter @carrierflow/admin typecheck
~~~

**Checkpoint:** step-14-pilot-privacy.

### Paso 15 — Verificar manifiestos Dokploy y gates de piloto

Archivos: infra/dokploy/docker-compose.production.yml, scripts/verify-local-restore.mjs, .github/workflows/verify.yml, tests/security/tenant-boundary.spec.ts, tests/a11y/critical-flows.spec.ts.

**DO**

Create the five listed Compose, local restore verifier, CI workflow, security test and a11y test files. Compose exposes only Traefik TLS; the script validates disposable inputs without production contact; CI declares separate typecheck/lint/test/pgTAP/admin-build/Playwright gates.

**Aceptación**

1. WHEN the production compose configuration is rendered THE SYSTEM SHALL isolate proxy, application, Supabase/data and monitoring on private networks and expose only TLS proxy ports.
2. WHEN the disposable local restore verifier runs in dry-run mode THE SYSTEM SHALL validate required backup inputs without contacting production or claiming an off-server restore.
3. WHEN the CI workflow declaration is inspected THE SYSTEM SHALL contain separate typecheck, lint, unit, pgTAP, production build and critical E2E commands.
4. WHEN tenant-boundary and critical accessibility suites run THE SYSTEM SHALL report no protected cross-company response and no automated violation in labelled critical controls.

**Verificar**

~~~bash
docker compose -f infra/dokploy/docker-compose.production.yml config
~~~
~~~bash
node scripts/verify-local-restore.mjs --dry-run
~~~
~~~bash
node -e "const fs=require('fs');const y=fs.readFileSync('.github/workflows/verify.yml','utf8');for(const x of ['pnpm typecheck','pnpm lint','pnpm test','pnpm exec supabase test db','pnpm --filter @carrierflow/admin build','pnpm exec playwright test'])if(!y.includes(x))process.exit(1)"
~~~
~~~bash
pnpm exec playwright test tests/security/tenant-boundary.spec.ts tests/a11y/critical-flows.spec.ts
~~~

**Checkpoint:** step-15-release-gates.



## 10. Environment Setup

### Prerequisites

Node 24.20.0 con Corepack/pnpm 11.24.0, Flutter 3.47.2/Dart 3.13.2, Docker, Android SDK/Xcode y Git. Este proyecto debe conservar las cinco skills project-scoped ya instaladas en la raíz .codex/skills; no se consulta ni copia un directorio de usuario.

### Accounts

Local no exige cuenta comercial. Antes de integrar cada servicio se necesitan Firebase/Apple, Google Routes, proveedor de tiles, Ubuntu/Dokploy y backup externo. Stripe queda fuera de piloto. Ningún agente crea recursos pagados autónomamente.

### Files to commit

Commit: lockfiles, .node-version, pnpm-workspace.yaml, source/tests/migrations, infra sin secretos, .env.example, root .codex/skills/{architect,using-superpowers,cyber-neo,ui-ux-pro-max,graphify}, docs y blueprint. Nunca commit .env, service role, credentials, volúmenes, backups, node_modules, .next o build.

### Bootstrap

Copiar el workspace de forma idempotente y de grano fino: crea solo directorios/archivos faltantes, no sobrescribe configuraciones o skills existentes.

~~~powershell
$source = Join-Path (Get-Location) 'blueprints\carrierflow\workspace'
Get-ChildItem -LiteralPath $source -Force -Recurse | ForEach-Object {
  $relative = $_.FullName.Substring($source.Length).TrimStart('\')
  $target = Join-Path (Get-Location) $relative
  if ($_.PSIsContainer) {
    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
  } elseif (-not (Test-Path -LiteralPath $target)) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Copy-Item -LiteralPath $_.FullName -Destination $target -Force
  }
}
~~~

Verificar los artefactos project-scoped exactos antes de instalar. Si falta uno, el checkout está corrupto/incompleto: restaurar el artefacto rastreado de este repositorio; no inventar ruta ni comando remoto.

~~~powershell
$requiredProjectSkills = @('architect','using-superpowers','cyber-neo','ui-ux-pro-max','graphify')
$requiredProjectSkills | ForEach-Object {
  $path = Join-Path (Get-Location) ".codex\skills\$_\SKILL.md"
  if (-not (Test-Path -LiteralPath $path)) { throw "Missing required project-scoped skill artifact: $path" }
}
~~~

Inicializar Git antes de instalaciones/checkpoints; los guards y el copy anterior terminan 0 al repetirse. No Verify de task exige commit/tag/archivo tracked antes de su Checkpoint.

~~~powershell
$gitDir = git rev-parse --git-dir 2>$null
if ($LASTEXITCODE -ne 0) {
  git init
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
git config --local user.name 2>$null
if ($LASTEXITCODE -ne 0) {
  git config --local user.name 'CarrierFlow Blueprint Builder'
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
git config --local user.email 2>$null
if ($LASTEXITCODE -ne 0) {
  git config --local user.email 'carrierflow-builder@local.invalid'
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
$head = git rev-parse --verify HEAD 2>$null
if ($LASTEXITCODE -ne 0) {
  git commit --allow-empty -m 'chore: initialize carrierflow'
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
pnpm install
pnpm exec supabase start
pnpm exec supabase db reset
pnpm exec supabase test db
pnpm exec playwright install chromium
~~~

Las ocho variables siguientes son el contrato exacto de .env.example; no hay variables Stripe en el bundle:

| Variable | Propósito | Origen | Required by |
|---|---|---|---|
| NEXT_PUBLIC_SUPABASE_URL | endpoint público | Dokploy/Supabase | Paso 2 |
| NEXT_PUBLIC_SUPABASE_ANON_KEY | sesión/RLS client | Supabase secrets | Paso 2 |
| SUPABASE_SERVICE_ROLE_KEY | server-only/FCM | Supabase secrets | Paso 3 |
| GOOGLE_ROUTES_API_KEY | RoutingProvider | Google Cloud restringido | Paso 7 |
| NEXT_PUBLIC_MAP_TILES_URL | tiles MapLibre | tiles provider | Paso 12 |
| FCM_SERVICE_ACCOUNT_JSON | push servidor | Firebase secret | Paso 13 |
| DOKPLOY_DOMAIN | domain/TLS | Dokploy | Paso 15 |
| BACKUP_TARGET | destino externo cifrado | backup provider | manual §20.1 |

Next usa .env.local, Flutter dart-define/secret manager y Supabase local config.toml. Supabase CLI local no es producción.


## 11. Dependencies

| Package | Version | Source | Checked | Installed by | Purpose |
|---|---:|---|---|---|---|
| Node | 24.20.0 | https://nodejs.org/dist/index.json | 2026-08-27 | .node-version / Bootstrap | runtime |
| pnpm | 11.24.0 | https://registry.npmjs.org/pnpm/latest | 2026-08-27 | packageManager / Bootstrap | workspace |
| Next | 16.3.3 | https://registry.npmjs.org/next/latest | 2026-08-27 | Paso 1 pnpm add | admin |
| React | 19.2.8 | https://registry.npmjs.org/react/latest | 2026-08-27 | Paso 1 pnpm add | UI |
| react-dom | 19.2.8 | https://registry.npmjs.org/react-dom/latest | 2026-08-27 | Paso 1 pnpm add | browser render |
| TypeScript | 6.0.3 | https://registry.npmjs.org/typescript/latest | 2026-08-27 | Paso 1 pnpm add | typecheck |
| Tailwind | 4.3.3 | https://registry.npmjs.org/tailwindcss/latest | 2026-08-27 | Paso 1 pnpm add | style |
| shadcn | 4.19.0 | https://registry.npmjs.org/shadcn/latest | 2026-08-27 | Paso 1 pnpm add | components |
| Vitest | 4.1.11 | https://registry.npmjs.org/vitest/latest | 2026-08-27 | Paso 1 pnpm add | unit test |
| Playwright | 1.62.1 | https://registry.npmjs.org/playwright/latest | 2026-08-27 | Paso 1 add/install chromium | E2E |
| Supabase CLI | 2.116.0 | https://registry.npmjs.org/supabase/latest | 2026-08-27 | Paso 1 pnpm add | local/pgTAP |
| supabase-js | 2.112.4 | https://registry.npmjs.org/%40supabase%2Fsupabase-js/latest | 2026-08-27 | Paso 2 pnpm add | client |
| supabase-ssr | 0.12.5 | https://registry.npmjs.org/%40supabase%2Fssr/latest | 2026-08-27 | Paso 2 pnpm add | Next session |
| maplibre-gl | 6.6.0 | https://registry.npmjs.org/maplibre-gl/latest | 2026-08-27 | Paso 1 pnpm add | web map |
| Flutter/Dart | 3.47.2/3.13.2 | https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json | 2026-08-27 | Paso 9 SDK | mobile |
| supabase_flutter | 2.17.2 | https://pub.dev/packages/supabase_flutter | 2026-08-27 | Paso 9 pubspec | Flutter auth/data |
| firebase_core | 4.14.0 | https://pub.dev/packages/firebase_core | 2026-08-27 | Paso 9 pubspec | Firebase |
| firebase_messaging | 16.6.0 | https://pub.dev/packages/firebase_messaging | 2026-08-27 | Paso 9 pubspec | push |
| drift | 2.34.3 | https://pub.dev/packages/drift | 2026-08-27 | Paso 9 pubspec | offline DB |
| drift_flutter | 0.3.1 | https://pub.dev/packages/drift_flutter | 2026-08-27 | Paso 9 pubspec | Drift platform |
| connectivity_plus | 7.3.1 | https://pub.dev/packages/connectivity_plus | 2026-08-27 | Paso 9 pubspec | network state |
| url_launcher | 6.3.2 | https://pub.dev/packages/url_launcher | 2026-08-27 | Paso 9 pubspec | Maps handoff |
| geolocator | 14.0.3 | https://pub.dev/packages/geolocator | 2026-08-27 | Paso 9 pubspec | GPS |
| workmanager | 0.10.9 | https://pub.dev/packages/workmanager | 2026-08-27 | Paso 9 pubspec | recovery |
| maplibre_gl | 0.27.0 | https://pub.dev/packages/maplibre_gl | 2026-08-27 | Paso 9 pub add | mobile map |

Future/uninstalled optional: Patrol 4.9.0 is reserved for a later device-regression decision; it has no Bootstrap or MVP installation command.

References: https://supabase.com/docs/guides/database/postgres/row-level-security ; https://supabase.com/docs/guides/realtime/subscribing-to-database-changes ; https://developer.android.com/develop/sensors-and-location/location/permissions/background ; https://developer.android.com/develop/background-work/services/fgs/service-types ; https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background ; https://firebase.google.com/docs/cloud-messaging/flutter/get-started ; https://developers.google.com/maps/documentation/routes/compute_route_matrix ; https://project-osrm.org/docs/ ; https://docs.dokploy.com/docs/core ; https://docs.dokploy.com/docs/core/installation ; https://supabase.com/docs/guides/self-hosting ; https://supabase.com/docs/guides/self-hosting/docker.


## 12. Deployment Strategy

Dokploy sobre Ubuntu 24.04 entrega Traefik, domain/TLS y deploy versionado. Compose separa proxy TLS, application web/API, Supabase self-host (Postgres/PostGIS/Auth/Storage/Realtime) y monitoring/backup. Solo proxy publica 80/443; Studio/DB/servicios internos van a redes privadas. Volúmenes persistentes tienen owner.

Secrets vía Dokploy/secret manager, nunca Git/Compose. Upgrade de imágenes/Supabase/Dokploy con version/changelog/backup/rollback. Backups cifrados a destino fuera del host y restore real fuera del servidor antes de piloto. Host único no es HA/DR. Sizing/cost, RTO/RPO, monitoring y alerts son gates. FCM/APNs/rutas/tiles externos son posibles.

## 13. Testing Strategy

pgTAP: RLS/state/audit/idempotencia. Unit web: rates/roles/entitlements/tokens. Playwright: HTTP smoke Paso 1, dispatch/security/a11y. Flutter: home/state/evidence/outbox/tracking. Compose/dry-run: estructura local, sin producción. Física/manual: GPS/push/cámara/batería Android/iOS.

## 14. Security & Secrets

RLS, validación, rate limits, Storage privada, URLs firmadas cortas, tokens públicos hasheados, audit/retención. Logs minimizan PII/GPS y no imprimen secretos. Cyber Neo remedia dentro del repo con diff/test/aviso; escala delete, secrets, gasto o sistema externo. Infra no expone Studio/Postgres; UFW, SSH keys, patches y puertos son manual gate.

## 15. Accessibility

WCAG 2.2 AA objetivo: contraste, landmarks, foco/teclado, label, texto no-color-only, errores/loading/retry, 44 px y reduced motion. UI UX Pro Max valida EN/ES, lector, tabla/mapa y flujo físico de §20.2.

## 16. Observability & Cost

Medir assignment→appearance, GPS freshness, outbox/retry, evidence, estimate invalidation/cost, FCM, capacity, CPU/RAM/disk y backup. Alertar por GPS stale, cola, backup/webhook/routing/RLS anomalía y capacidad. Antes del piloto, cost model de host, backup externo, storage, tiles/rutas/FCM.

## 17. Model Routing

NOT APPLICABLE — MVP no usa IA/LLM. RoutingProvider es rutas geográficas, no routing de modelos.

## 18. Skills to Use During Build

Las cinco skills son artefactos obligatorios project-scoped y rastreados en la raíz de este repositorio: .codex/skills/architect/SKILL.md, .codex/skills/using-superpowers/SKILL.md, .codex/skills/cyber-neo/SKILL.md, .codex/skills/ui-ux-pro-max/SKILL.md y .codex/skills/graphify/SKILL.md. Bootstrap solo verifica esas rutas. Si falta una, restaurar el checkout del repositorio; no usar fuente externa ni inventar comando remoto.

| Skill | When / why | Project artifact verification | Fallback |
|---|---|---|---|
| architect | scope, data, deploy architecture | Test-Path .codex/skills/architect/SKILL.md | blueprint review |
| using-superpowers | every task TDD/debug/verify | Test-Path .codex/skills/using-superpowers/SKILL.md | AGENTS/tests |
| cyber-neo | 3,11,15/pre-beta audit/remediate | Test-Path .codex/skills/cyber-neo/SKILL.md | documented SAST/SCA/secrets |
| ui-ux-pro-max | 4,8–10,12,15 UI/a11y/EN-ES | Test-Path .codex/skills/ui-ux-pro-max/SKILL.md | §§7/15/tests |
| graphify | memory before/after broad edits | Test-Path .codex/skills/graphify/SKILL.md; graphify --version or py -m graphify --help | rg/docs |

Architect directs, Superpowers implements, Cyber Neo remediates/notifies, UI UX owns UX and Graphify maintains memory. Cyber Neo escalates only destructive data, secrets, spending, external irreversible changes or production access.


## 19. Agent Workspace

### 19.1 AGENTS.md

workspace/AGENTS.md is canonical, under 200 lines, commands first, and records product non-negotiables plus autonomy.

### 19.2 Companion instructions

NOT APPLICABLE — Codex uses AGENTS.md; no parallel instruction file is emitted.

### 19.3 settings.json

workspace/.codex/settings.json grants only literal Bootstrap/§9/§20 commands: separate pnpm gates, exact initial package adds, exact Flutter pub adds, Supabase, Playwright, local restore dry-run, workflow inspection, Docker config and git checkpoint/config. It does not grant generic shell/deploy/secret access.

### 19.4 Project skills

Root .codex/skills is a required tracked CarrierFlow artifact, not an installer target. workspace/.codex/skills/project-skills.manifest.json declares the required root-relative folders; Bootstrap verifies .codex/skills/<name>/SKILL.md exactly and fails only when this repository artifact is missing/corrupt. workspace/.codex/skills/carrierflow-governance/SKILL.md adds project governance but never replaces the five installed skills.

### 19.5 Deferred rules

workspace/.codex/rules/database.md, security.md, ui.md and mobile.md have paths frontmatter. No .codex/commands is emitted.

### 19.6 Verify-critical configuration and reconciliation

**Resolution/config matrix**

| Context | Imports/entry | Config that resolves it | Verification |
|---|---|---|---|
| Next admin | @carrierflow/* and app entry | tsconfig.base.json paths, apps/admin package scripts | Paso 1 typecheck/build |
| Vitest | workspace test modules | vitest.workspace.ts | pnpm test |
| Playwright | tests/*.spec.ts → admin production entry | playwright.config.ts webServer start | Paso 1/§20.1 Playwright |
| Flutter | package imports in pubspec | apps/driver/pubspec.yaml | flutter analyze/test |
| pgTAP | supabase/tests/database/*.sql | supabase/config.toml | pnpm exec supabase test db |

**Bundle-path exclusion matrix**

| Tree walker | Literal exclusion | Location | Compared |
|---|---|---|---|
| TypeScript | blueprints/** | tsconfig.base.json exclude | yes |
| Vitest | **/blueprints/** | vitest.workspace.ts test.exclude | yes |
| Playwright | **/blueprints/** | playwright.config.ts testIgnore | yes |
| pnpm | apps/* and packages/* only | pnpm-workspace.yaml | yes |

**Cross-artifact values**

| Value | Source of truth | Consumers/locations | Compared |
|---|---|---|---|
| 127.0.0.1:3000 | playwright.config.ts baseURL | webServer URL, HTTP smoke, §20.1 | yes |
| apps/admin | pnpm-workspace.yaml | package scripts, Playwright command, tasks | yes |
| supabase/tests/database | Supabase CLI convention/config.toml | task files, pgTAP command | yes |
| blueprints/** | config exclusions above | TypeScript/Vitest/Playwright | yes |
| infra/dokploy/docker-compose.production.yml | Paso 15 task file | Docker verify, AGENTS, §20.1 | yes |

**Byte-exact reconciliation**

NOT APPLICABLE — no golden file, snapshot baseline or byte-exact fixture is emitted by this bundle. SQL fixtures are behavior tests, not predicted literals.


## 20. Acceptance Gate, Risks & Decision Log

### 20.1 Global acceptance

Run separate commands, in order. The admin build creates the production artifact; Playwright owns webServer lifecycle and starts pnpm --filter @carrierflow/admin start only after that build, then HTTP smoke asserts 200.

~~~bash
pnpm typecheck
pnpm lint
pnpm test
pnpm --filter @carrierflow/admin build
pnpm exec supabase test db
pnpm exec playwright test tests/smoke/admin-http.spec.ts tests/security/tenant-boundary.spec.ts tests/a11y/critical-flows.spec.ts
docker compose -f infra/dokploy/docker-compose.production.yml config
~~~

There must be 15 tags step-01 through step-15. A failure returns to the first pending task. Manual launch evidence includes a PowerShell re-run of the exact §10 Bootstrap in the same project root, with no commit or tag requirement. Run this evidence wrapper, paste/run the exact §10 Bootstrap blocks between the marked lines, then retain its console output:

~~~powershell
$evidencePaths = @(
  '.codex/skills/architect/SKILL.md', '.codex/skills/using-superpowers/SKILL.md',
  '.codex/skills/cyber-neo/SKILL.md', '.codex/skills/ui-ux-pro-max/SKILL.md',
  '.codex/skills/graphify/SKILL.md', '.codex/settings.json', 'AGENTS.md'
) | Where-Object { Test-Path -LiteralPath $_ }
$before = $evidencePaths | ForEach-Object { Get-FileHash -Algorithm SHA256 -LiteralPath $_ }
# Run the exact §10 Bootstrap copy, skill-verification, Git-guard and install blocks here a second time.
if ($LASTEXITCODE -ne 0) { throw "Bootstrap re-run failed with exit code $LASTEXITCODE" }
$after = $evidencePaths | ForEach-Object { Get-FileHash -Algorithm SHA256 -LiteralPath $_ }
foreach ($item in $before) {
  $match = $after | Where-Object { $_.Path -eq $item.Path }
  if ($null -eq $match -or $match.Hash -ne $item.Hash) { throw "Bootstrap overwrote existing artifact: $($item.Path)" }
}
Write-Output 'Bootstrap re-run: exit 0; existing workspace and skills unchanged.'
~~~

Manual launch evidence also includes: physical Android/iOS permissions/background/offline/push/camera/battery; Cyber Neo and UI UX reports; Ubuntu SSH/UFW/TLS/patch/secrets/monitoring/ports; real DB+object restore to a non-production target from backup outside host; external CI PR run; sizing/cost approval, two tenants/token revoke/privacy/no checkout; store approval only after official response.

### 20.2 Risks

| Risk | Mitigation |
|---|---|
| GPS/stores/battery | disclosure, physical test, honest degraded state |
| external cost | adapter/cache/budget |
| tenant leak | RLS/pgTAP/Cyber Neo |
| offline duplicate | outbox/idempotency |
| single host | backup/restore/monitoring, no HA claim |
| scope creep | non-goals/15 tasks |

### 20.3 Decision log

| Decision | State | Consequence |
|---|---|---|
| mandatory assignment | confirmed | no driver accept/reject |
| empty/loaded/total | confirmed | auditable revisions |
| multi-stop ready, 1+1 pilot | confirmed | ordered model |
| bilingual Android/iOS | confirmed | EN/ES and physical gates |
| private pilot/no billing | confirmed | entitlement yes, payment no |
| Ubuntu Dokploy self-host | confirmed | operator owns hardening/backup/DR |

### 20.4 What to build next / backlog

After pilot gates: customer portal controls, multiple-stop UI expansion, advanced signatures, geofencing/alerts, public production billing, route provider cost optimization/OSRM evaluation, ELD/load board research and HA/DR architecture only after measured RTO/RPO and demand.

Handoff: C:\Users\sami\Documents\ChatGPT\Carrier Flow\blueprints\carrierflow\. Copy workspace via §10, choose first pending task in tasks.json and execute its epic. Next command: /architect-next.
