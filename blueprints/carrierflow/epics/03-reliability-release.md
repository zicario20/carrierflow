# Epic 03 — Confiabilidad, privacidad y piloto

## Objetivo

Garantizar offline/idempotencia, GPS seguro, tracking limitado, entitlements y gates Dokploy.

## Contratos

- Sync usa client_mutation_id
- current/history separados
- proxy TLS es único puerto público.

## Tareas

### E3-T1 — Añadir outbox offline e idempotencia

**Dependencias:** E2-T5  
**Prioridad:** p0  
**Archivos:** supabase/migrations/0006_sync_operations.sql, apps/driver/lib/core/sync/outbox.dart, apps/driver/lib/core/sync/sync_worker.dart, apps/driver/test/outbox_test.dart, apps/admin/src/server/sync/idempotency-service.test.ts

**Dirección / DO**

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

**Checkpoint**

~~~bash
git add -A && git commit -m "E3-T1: Añadir outbox offline e idempotencia"
git tag step-11-offline-sync
~~~

---

### E3-T2 — Seguimiento, mapa y permisos degradados

**Dependencias:** E1-T5, E2-T3, E2-T5  
**Prioridad:** p0  
**Archivos:** supabase/migrations/0007_locations.sql, apps/driver/lib/features/tracking/tracking_service.dart, apps/driver/lib/features/tracking/tracking_permission_state.dart, apps/driver/test/tracking_service_test.dart, apps/driver/android/app/src/main/AndroidManifest.xml

**Dirección / DO**

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

**Checkpoint**

~~~bash
git add -A && git commit -m "E3-T2: Seguimiento, mapa y permisos degradados"
git tag step-12-tracking-map
~~~

---

### E3-T3 — Notificar y compartir tracking limitado

**Dependencias:** E3-T2  
**Prioridad:** p1  
**Archivos:** supabase/migrations/0008_notifications_public_links.sql, apps/admin/src/server/notifications/notification-service.ts, apps/admin/src/app/api/public/track/[token]/route.ts, apps/driver/lib/core/push/push_service.dart, apps/admin/tests/public-tracking-link.test.ts

**Dirección / DO**

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

**Checkpoint**

~~~bash
git add -A && git commit -m "E3-T3: Notificar y compartir tracking limitado"
git tag step-13-notifications-tracking
~~~

---

### E3-T4 — Aplicar entitlements y retención piloto

**Dependencias:** E1-T5, E3-T1  
**Prioridad:** p1  
**Archivos:** supabase/migrations/0009_entitlements_retention.sql, apps/admin/src/server/billing/entitlement-service.ts, apps/admin/src/server/privacy/retention-service.ts, apps/admin/src/app/(ops)/settings/plan/page.tsx, apps/admin/tests/entitlement-service.test.ts

**Dirección / DO**

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

**Checkpoint**

~~~bash
git add -A && git commit -m "E3-T4: Aplicar entitlements y retención piloto"
git tag step-14-pilot-privacy
~~~

---

### E3-T5 — Verificar manifiestos Dokploy y gates de piloto

**Dependencias:** E3-T1, E3-T2, E3-T3, E3-T4  
**Prioridad:** p0  
**Archivos:** infra/dokploy/docker-compose.production.yml, scripts/verify-local-restore.mjs, .github/workflows/verify.yml, tests/security/tenant-boundary.spec.ts, tests/a11y/critical-flows.spec.ts

**Dirección / DO**

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

**Checkpoint**

~~~bash
git add -A && git commit -m "E3-T5: Verificar manifiestos Dokploy y gates de piloto"
git tag step-15-release-gates
~~~


---

## Aceptación del epic

1. WHEN all tasks in this epic are complete THE SYSTEM SHALL satisfy every task acceptance criterion through its declared local verification.
2. WHEN an invalid, unauthorized or degraded path is exercised THE SYSTEM SHALL preserve tenant isolation, ordered load state and a typed recoverable response.

## Pitfalls

- No prometer tracking tras force quit
- token público no expone documentos
- host único no es HA.

## Antes de avanzar

- [ ] Cada task es done en tasks.json después de verify.
- [ ] Cada checkpoint coincide literalmente con tasks.json.
- [ ] No se modificó una migration aplicada ni se introdujo secreto.
- [ ] Cambios de código/documentación se registraron en Graphify cuando esté disponible.

