# CarrierFlow — Diseño aprobado

**Fecha:** 2026-08-27 · **Estado:** aprobado por producto para blueprint y piloto privado

## Resultado buscado

Un SaaS multi-tenant para carriers de Estados Unidos. El dispatcher administra y asigna cargas obligatorias; el conductor ejecuta, se guía, comparte ubicación conforme a permisos y registra pruebas. Se entrega como panel administrativo web y aplicación Flutter para Android/iOS.

## Decisiones confirmadas

- Modelo B2B SaaS: planes iniciales de 10, 25 y 60 conductores; piloto privado por invitación, sin cobro real antes de aprobación de tiendas.
- Mercado/base USD en Estados Unidos; paradas transfronterizas a Canadá permitidas sin alcance inicial de billing/tax/legal canadiense.
- Vehículos mixtos: cargo van, box truck, hotshot y semitruck.
- Los conductores no aceptan, rechazan, cancelan ni reasignan. Admin/dispatcher es el único actor que asigna, reasigna, cancela y cierra.
- Modelo de paradas ordenadas desde inicio; interfaz piloto para un pickup y una entrega.
- Mapa dentro de app para contexto y botones a Google Maps/Apple Maps. No se promete enrutamiento apto/legal para camiones.
- Ubicación durante turno activo con app visible/logueada; segundo plano durante carga activa cuando permiso y SO lo permiten. Force-quit o permiso revocado se presenta como limitación, no como fallo oculto.
- Evidencia configurable por carga/cliente: firma/nombre, BOL/POD, referencia, ubicación/tiempo y fotografía independiente/posiblemente opcional.
- App bilingüe English/Español. La siguiente carga es visible sin competir con la carga activa.
- Link público opcional de tracking, opaco, de una carga, revocable/expirable y sin documentos privados.
- Dispatcher ingresa el precio. La app muestra **por separado** millas vacías, millas cargadas, total y dólares por milla total. Si hay carga activa, las millas vacías de la siguiente comienzan en la última entrega planificada de la activa, no en el GPS actual. Todo recálculo es una revisión auditable.
- Despliegue self-hosted first en Ubuntu Server con Dokploy/Docker Compose para reducir suscripciones. Supabase/Postgres autoalojado es posible pero requiere backups, restore, hardening, monitoring y actualizaciones propios.

## Diseño de experiencia

La aplicación debe sentirse como una herramienta operacional de confianza, no un panel futurista.

- Light-first: fondo `#F8FAFC`, superficie `#FFFFFF`, texto `#0F172A`, primario `#0F6CBD`, éxito `#067647`, advertencia `#B54708`, destructivo `#B42318`, borde `#CBD5E1`, texto secundario `#475569`; modo oscuro opcional `#0F172A`/`#172033`.
- Inter para UI y una fuente monoespaciada para millas, ETA, códigos y montos. Estado nunca solo por color; incluir etiqueta e ícono.
- Dispatcher: tablero de alta densidad con tabla + mapa, filtros persistentes, búsqueda y estados/alertas entendibles.
- Driver: acciones de carga prominentes, objetivo táctil mínimo de 44px, indicador claro de GPS/red/sync, una acción primaria por etapa y la carga siguiente en zona secundaria.
- Accesibilidad: contraste WCAG AA, teclado/lector de pantalla en web, foco visible, formularios con error útil, reduced motion y transiciones de 150–200 ms máximo.

## Límites que no se deben reinterpretar

El cálculo de tarifa es guía económica, no nómina ni garantía de coste real. La GPS, ETA y rutas son mejor esfuerzo con estado de frescura. El producto no debe aceptar internamente una carga en nombre de un conductor, exponer datos entre carriers ni convertir una incidencia en cancelación silenciosa.

## Gates previos a piloto

1. Pruebas automatizadas de RLS/tenant, transiciones, idempotencia offline, requisitos de evidencia, links públicos y límites de plan.
2. Pruebas físicas de Android/iOS: permisos, tracking background, push, offline, documentos, navegación externa e idiomas.
3. Auditoría Cyber Neo con corrección autónoma de hallazgos en scope y registro de riesgo residual.
4. Revisión UI UX Pro Max de flujos, estados, contraste, idiomas y accesibilidad.
5. Despliegue Dokploy repetible, backup cifrado externo y restauración ensayada.
