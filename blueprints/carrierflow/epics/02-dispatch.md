# Epic 02 — Despacho, tarifa y conductor

## Objetivo

Construir cargas obligatorias, millas revisionadas, UI dispatcher y ejecución Flutter.

## Contratos

- Servidor valida estado
- empty/loaded/total se separan
- next deadhead inicia en final planificado.

## Tareas

### E2-T1 — Modelar cargas, evidencia y estados

**Dependencias:** E1-T5  
**Prioridad:** p0  
**Archivos:** supabase/migrations/0004_loads.sql, supabase/tests/database/0004_loads.sql, apps/admin/src/server/loads/load-service.ts, apps/admin/src/server/loads/load-state-machine.test.ts, apps/admin/src/app/(ops)/loads/[loadId]/page.tsx

**Dirección / DO**

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

**Checkpoint**

~~~bash
git add -A && git commit -m "E2-T1: Modelar cargas, evidencia y estados"
git tag step-06-load-domain
~~~

---

### E2-T2 — Calcular millas y revisiones de tarifa

**Dependencias:** E2-T1  
**Prioridad:** p0  
**Archivos:** supabase/migrations/0005_route_estimates.sql, apps/admin/src/server/routing/routing-provider.ts, apps/admin/src/server/routing/estimate-service.ts, apps/admin/src/server/routing/estimate-service.test.ts, packages/routing-contract/src/index.ts

**Dirección / DO**

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

**Checkpoint**

~~~bash
git add -A && git commit -m "E2-T2: Calcular millas y revisiones de tarifa"
git tag step-07-routing-pricing
~~~

---

### E2-T3 — Crear flujo web de propuesta y asignación

**Dependencias:** E2-T1, E2-T2, E1-T4  
**Prioridad:** p0  
**Archivos:** apps/admin/src/app/(ops)/loads/new/page.tsx, apps/admin/src/components/loads/load-form.tsx, apps/admin/src/components/loads/mileage-breakdown.tsx, apps/admin/tests/load-dispatch-flow.spec.ts, apps/admin/src/app/(ops)/map/page.tsx

**Dirección / DO**

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

**Checkpoint**

~~~bash
git add -A && git commit -m "E2-T3: Crear flujo web de propuesta y asignación"
git tag step-08-dispatch-ui
~~~

---

### E2-T4 — Inicializar Flutter y lista actual/siguiente

**Dependencias:** E2-T1, E1-T4  
**Prioridad:** p0  
**Archivos:** apps/driver/pubspec.yaml, apps/driver/lib/main.dart, apps/driver/lib/features/auth/auth_gate.dart, apps/driver/lib/features/loads/load_home_page.dart, apps/driver/test/load_home_page_test.dart

**Dirección / DO**

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

**Checkpoint**

~~~bash
git add -A && git commit -m "E2-T4: Inicializar Flutter y lista actual/siguiente"
git tag step-09-driver-shell
~~~

---

### E2-T5 — Ejecutar carga y evidencia en móvil

**Dependencias:** E2-T1, E2-T4  
**Prioridad:** p0  
**Archivos:** apps/driver/lib/features/loads/load_detail_page.dart, apps/driver/lib/features/loads/load_state_controller.dart, apps/driver/lib/features/evidence/evidence_capture.dart, apps/driver/test/load_state_controller_test.dart, apps/driver/test/evidence_requirements_test.dart

**Dirección / DO**

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

**Checkpoint**

~~~bash
git add -A && git commit -m "E2-T5: Ejecutar carga y evidencia en móvil"
git tag step-10-driver-execution
~~~


---

## Aceptación del epic

1. WHEN all tasks in this epic are complete THE SYSTEM SHALL satisfy every task acceptance criterion through its declared local verification.
2. WHEN an invalid, unauthorized or degraded path is exercised THE SYSTEM SHALL preserve tenant isolation, ordered load state and a typed recoverable response.

## Pitfalls

- No accept/reject
- evidencia por carga/cliente
- no prometer ruteo de camiones.

## Antes de avanzar

- [ ] Cada task es done en tasks.json después de verify.
- [ ] Cada checkpoint coincide literalmente con tasks.json.
- [ ] No se modificó una migration aplicada ni se introdujo secreto.
- [ ] Cambios de código/documentación se registraron en Graphify cuando esté disponible.

