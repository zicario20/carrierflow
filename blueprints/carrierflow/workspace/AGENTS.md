# CarrierFlow — instrucciones de agentes

SaaS B2B multi-tenant de cargas para EE. UU. con Next.js, Flutter y Supabase autoalojado.

## Comandos

| Tarea | Comando |
|---|---|
| Bootstrap packages | pnpm install |
| Inicializar DB | pnpm exec supabase start ; pnpm exec supabase db reset ; pnpm exec supabase test db |
| Admin checks | pnpm --filter @carrierflow/admin typecheck ; pnpm --filter @carrierflow/admin lint ; pnpm --filter @carrierflow/admin test [path] |
| Build/entry producción | pnpm --filter @carrierflow/admin build ; pnpm --filter @carrierflow/admin start |
| Playwright | pnpm exec playwright install chromium ; pnpm exec playwright test tests/smoke/admin-http.spec.ts tests/security/tenant-boundary.spec.ts tests/a11y/critical-flows.spec.ts |
| Flutter | cd apps/driver && flutter pub get ; cd apps/driver && flutter test [path] ; cd apps/driver && flutter analyze |
| Restore dry-run | node scripts/verify-local-restore.mjs --dry-run |
| Inspección workflow | node -e "const fs=require('fs');const y=fs.readFileSync('.github/workflows/verify.yml','utf8');for(const x of ['pnpm typecheck','pnpm lint','pnpm test','pnpm exec supabase test db','pnpm --filter @carrierflow/admin build','pnpm exec playwright test'])if(!y.includes(x))process.exit(1)" |
| Compose | docker compose -f infra/dokploy/docker-compose.production.yml config |
| Global acceptance | pnpm typecheck ; pnpm lint ; pnpm test ; pnpm --filter @carrierflow/admin build ; pnpm exec supabase test db ; Playwright/Compose arriba |

No task Verify queda fuera de esta tabla. Playwright controla el ciclo: el config arranca admin start tras build y detiene el proceso al acabar.

## Arquitectura

Web/Flutter consumen service/RPC autorizado. RLS deriva company_id de membership. service role solo servidor. Mutaciones son transaccionales/auditadas/resultados tipados. Offline usa client_mutation_id. current location e history son modelos distintos. Producción es Ubuntu/Dokploy/Supabase self-host detrás de Traefik; proxy TLS es lo único público.

## No negociable

1. La asignación es obligatoria: nunca accept/reject/cancel/reassign por driver.
2. delivered exige picked_up y evidencia configurada; una incidencia no cancela.
3. Toda fila comercial respeta RLS/tenant; jamás confiar company_id cliente.
4. Mostrar empty/loaded/total separados; próxima carga sale del final planificado, no GPS actual.
5. No prometer GPS tras force-quit/permisos revocados ni navegación certificada pesada.
6. Nunca versionar/imprimir secretos, service role, credenciales o .env real.
7. Studio/Postgres/documentos privados/tracking público no exceden su scope.
8. No alterar producción, borrar datos, rotar secretos o gastar dinero sin escalación.

## Autonomía

Architect mantiene la arquitectura. Superpowers implementa con TDD/debug/verify/checkpoint. Cyber Neo corrige fallas de seguridad en el repo, prueba, registra y avisa; escala delete/secret/gasto/externo irreversible. UI UX Pro Max es dueño de tokens/a11y/EN-ES. Graphify se consulta antes de explorar y se actualiza tras cambios: graphify update . o py -m graphify si CLI no está en PATH.

Leer la regla diferida del dominio antes de editarlo.

