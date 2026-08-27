# PRD — CarrierFlow

**Versión:** 1.0 · **Estado:** Aprobado para diseño y piloto privado · **Mercado inicial:** Estados Unidos (viajes transfronterizos a Canadá permitidos) · **Moneda comercial:** USD

## 1. Decisión de producto

CarrierFlow será una plataforma SaaS centralizada para que carriers, dueños de flota y dispatchers creen, coticen, asignen, sigan y cierren cargas. Consta de una aplicación Flutter para conductores (Android e iOS) y un panel administrativo web. El piloto será privado y por invitación. No habrá cobros reales hasta completar las aprobaciones de Apple App Store y Google Play; la arquitectura de planes, límites y auditoría de suscripciones sí existe desde el primer despliegue.

La aplicación no es un load board ni un sistema de ofertas para conductores. Una vez que un dispatcher autorizado asigna una carga, esta es obligatoria para el conductor: la app informa y guía, pero no presenta controles para aceptar, rechazar, reasignar ni cancelar.

## 2. Problema y oportunidad

Los carriers pequeños coordinan por teléfono, texto, hojas de cálculo, navegación aislada y fotografías dispersas. Eso provoca errores de dirección, poca visibilidad, pérdidas de BOL/POD, retrasos detectados tarde y un historial insuficiente para operar o resolver incidencias.

CarrierFlow concentra la operación con una distinción importante para el negocio: antes y durante la asignación, el dispatcher puede ver la economía operacional del viaje en millas vacías, millas cargadas y tarifa efectiva; el conductor recibe una guía de ejecución clara y solo la información de pago que dispatch autorice mostrarle.

## 3. Objetivos, no objetivos y principios

### Objetivos del MVP

- Operar múltiples empresas aisladas en una misma plataforma.
- Crear, cotizar, asignar y supervisar cargas obligatorias.
- Mostrar millas vacías, millas cargadas, millas totales y dólares por milla total con una regla determinista y auditable.
- Guiar al conductor por pickup, entrega y próximas cargas sin bloquear la carga activa.
- Mantener visibilidad operacional durante turno activo y, para una carga activa, en segundo plano cuando el sistema operativo lo permita.
- Recoger evidencia configurable de pickup y entrega, gestionar incidencias y preservar auditoría.
- Funcionar con conectividad limitada sin duplicar mutaciones críticas.
- Desplegar el piloto de forma económica en un servidor Ubuntu propio con Dokploy.

### No objetivos del MVP

- Subastas, aceptación/rechazo de carga o asignación automática.
- Nómina, liquidaciones, factoring, facturación de clientes o cálculo automático de combustible.
- ELD, load boards, optimización automática de flota, navegación certificada para camiones o validación legal de rutas.
- Chat avanzado, pagos al conductor, múltiples conductores por carga o analítica predictiva.
- Operación comercial/tax/legal localizada en Canadá. Canadá solo se soporta como origen/destino de un viaje.
- Alta disponibilidad multi-región. El primer despliegue usa un servidor y declara sus límites operativos.

### Principios de producto

1. **La operación antes que la decoración.** Toda pantalla prioriza la siguiente acción segura.
2. **Un estado es una promesa verificable.** Los cambios de carga se validan en servidor, se auditan y no se saltan pasos.
3. **Separar información no es ocultar operación.** El conductor ve lo necesario para ejecutar; las finanzas internas de carrier/broker quedan para roles autorizados.
4. **Offline no significa ambiguo.** Cada mutación crítica tiene idempotencia y evidencia de sincronización.
5. **La ubicación es sensible.** Se minimiza, explica, retiene según política y se marca como desactualizada cuando corresponde.
6. **Self-hosted no significa sin operación.** Menos suscripciones se compensa con backups, hardening, actualizaciones y monitoreo propios.

## 4. Modelo comercial y tenancy

CarrierFlow es un SaaS B2B multi-tenant. Cada empresa tiene una organización, miembros, conductores, vehículos, cargas, documentos y políticas propios. Ninguna consulta, almacenamiento, URL pública ni evento en tiempo real puede cruzar organizaciones.

| Plan inicial | Precio objetivo mensual | Límite de conductores activos |
|---|---:|---:|
| Starter | USD 20 | 10 |
| Growth | USD 40 | 25 |
| Fleet | USD 60 | 60 |

El piloto privado usa invitaciones y una suscripción/entitlement de prueba, sin cobro real. Al abrir la comercialización se habilitará checkout web alojado y webhooks idempotentes. Se podrá ofrecer una prueba de 7 días o un primer mes de USD 1, pero esa elección y su copy no se activan hasta la aprobación explícita de lanzamiento.

**Regla de capacidad:** un conductor activo cuenta contra el límite de su organización. El sistema debe impedir activar/invitar/asignar capacidad por encima del entitlement y explicar la acción de upgrade sin bloquear datos existentes.

## 5. Usuarios y permisos

| Rol | Puede | No puede |
|---|---|---|
| Owner | Administrar empresa, planes, usuarios, configuraciones, cargas, vehículos y auditoría | Eludir auditoría o datos de otra empresa |
| Admin | Administrar cargas, dispatchers, conductores, vehículos, evidencia e incidencias | Gestionar facturación/propiedad si Owner lo restringe |
| Dispatcher | Crear/cotizar/asignar/reasignar/cancelar cargas, configurar evidencia, monitorizar operación | Cambiar propiedad/plan si no tiene permiso delegado |
| Driver | Ver perfil, vehículo autorizado, carga actual/próxima, navegación, estados permitidos, incidencias y evidencia propia | Aceptar/rechazar, cancelar, reasignar, editar direcciones, ver otros conductores/cargas o información financiera no autorizada |

Las autorizaciones se aplican en la API/operación de servidor y RLS, no solo al ocultar botones.

## 6. Alcance operativo y geográfico

- La empresa, precios, planes y soporte se centran en Estados Unidos y USD.
- Una parada guarda país, estado/provincia, dirección normalizada, coordenadas, zona horaria IANA y contacto. Esto permite pickups o entregas en Canadá.
- Las ventanas, historial y ETA se muestran en la zona horaria local de la parada y, cuando ayude a dispatch, también en la zona de la organización.
- La app no promete requisitos de aduana, manifiestos transfronterizos, impuestos canadienses ni rutas legales para vehículo pesado. Esas necesidades se evaluarán como una futura capacidad independiente.

## 7. Carga, paradas y ciclo de vida

El modelo utiliza una lista ordenada de paradas desde el inicio, aunque el piloto solo expone un pickup y una entrega. Esto evita migrar datos al añadir rutas con múltiples pickups/entregas.

### Estados administrativos

`draft` → `scheduled` → `assigned` → `cancelled` o `closed`.

`reassigned` es un evento de auditoría de asignación, no un estado terminal que borra el estado operacional. `cancelled` y `closed` solo los ejecuta un rol autorizado.

### Estados operacionales

`assigned` → `en_route_to_pickup` → `arrived_pickup` → `loading` → `picked_up` → `en_route_to_delivery` → `arrived_delivery` → `unloading` → `delivered`.

Los estados pueden soportar varias paradas mediante la parada actual y su secuencia. Un evento de incidencia (`pickup_issue`, `delivery_issue`, `breakdown`, `bad_address`, `customer_unavailable`, `site_rejected_load`, `accident_emergency`, `awaiting_instruction`) conserva la carga activa y requiere resolución de dispatcher/admin; no la cancela automáticamente.

### Reglas inviolables

- No se puede marcar `delivered` sin haber completado `picked_up` y los requisitos de evidencia configurados.
- Una reasignación registra actor, conductor anterior/nuevo, motivo, fecha y versión de la ruta. El conductor anterior deja de verla como activa y ambos reciben una notificación.
- Cambiar una parada, ventana, vehículo, conductor, evidencia o tarifa crea un evento de auditoría con valores antes/después o referencia a la revisión.
- El cierre es una revisión administrativa posterior a entrega; no modifica las pruebas del conductor.

## 8. Flujo de dispatcher

1. Crea borrador: número de carga, cliente/broker, mercancía, vehículo requerido, peso/dimensiones, referencias, contactos, documentos e instrucciones.
2. Define pickup y entrega (o paradas futuras), ventanas, prioridades y requisitos de evidencia.
3. Ingresa el precio cotizado en USD y solicita/revisa la estimación de ruta.
4. Selecciona conductor y vehículo elegibles. La aplicación calcula el punto de origen de millas vacías según la regla de continuidad de carga.
5. Revisa millas vacías, millas cargadas, total, tarifa por milla total, fuente/fecha de ruta y posibles datos desactualizados.
6. Guarda/asigna. La carga aparece de inmediato para el conductor como obligatoria y se registra la auditoría.
7. Monitoriza ubicación, estado, ETA, incidencias, evidencia y sincronización. Reasigna o cancela solo con permisos.
8. Revisa POD/evidencia/horas/incidencias y cierra la carga.

## 9. Precio y millas: contrato de cálculo

### Campos y fórmula

| Campo | Definición |
|---|---|
| `quoted_amount_usd` | Precio ingresado por dispatcher para la carga; no es nómina calculada por CarrierFlow |
| `empty_miles` | Distancia estimada desde el origen operativo de pickup hasta el primer pickup |
| `loaded_miles` | Suma estimada de trayectos que llevan mercancía, desde pickup hasta la última entrega planificada |
| `total_estimated_miles` | `empty_miles + loaded_miles` |
| `quoted_usd_per_total_mile` | `quoted_amount_usd / total_estimated_miles`, redondeado solo para presentación; el valor y precisión de cálculo se guardan |

La interfaz **no combina visualmente** las millas vacías y cargadas en una métrica ambigua: ambas aparecen separadas, además del total necesario para la tarifa por milla. Si la distancia no es calculable, no se inventa una tarifa; se muestra el motivo, proveedor y acción de reintento/edición.

### Origen de millas vacías

1. Para la primera carga sin carga activa, usar la última ubicación aceptable del conductor si cumple la política de frescura; de lo contrario, usar la base declarada y etiquetar la estimación.
2. Si el conductor tiene una carga activa y se cotiza/asigna una carga siguiente, el origen es la **última parada de entrega planificada de la carga activa**, nunca la GPS actual del vehículo.
3. Si cambia la entrega final, el conductor, la asignación o las paradas relevantes de la carga activa, se recalcula la estimación de la carga siguiente. Se crea una nueva revisión inmutable con causa, rutas, proveedor, parámetros, actor/origen automático y fecha; dispatcher recibe alerta.
4. La tarifa mostrada al conductor es solo la cantidad/rate que dispatcher haya autorizado. El ingreso del broker, margen y otras finanzas son visibilidad administrativa.

El sistema registra rutas como estimaciones operacionales. No garantiza tráfico, distancia real, combustible, peajes, ruta legal para camión ni pago final.

## 10. Aplicación de conductor

### Inicio y turnos

El conductor inicia con correo/contraseña o teléfono/código, según la opción habilitada. La sesión es segura, se muestra idioma English/Español y se puede marcar inicio/fin de turno. Durante un turno activo y la app visible/logueada, la app intenta reportar ubicación. No debe presentar un interruptor oculto que simule un estado de tracking que el sistema operativo denegó.

### Inicio

La pantalla principal presenta carga actual, próxima parada, ventana, estado, distancia/ETA estimados, estado de ubicación/sincronización y la siguiente carga asignada. La próxima carga es consultable, pero las acciones prominentes corresponden solo a la carga activa.

### Detalle de carga

Incluye número, paradas, contactos, referencias, mercancía, peso/dimensiones, instrucciones, documentos permitidos, historial, requisitos de evidencia, estado, incidencias y botón de navegación. El mapa está integrado para orientación contextual y ofrece abrir Google Maps o Apple Maps. La navegación externa no se anuncia como navegación certificada para vehículos pesados.

### Pickup, entrega e incidencias

El conductor marca llegada, inicia carga/descarga, adjunta evidencia permitida, añade observaciones y avanza por estados permitidos. Antes de entregar, la app muestra los requisitos obligatorios configurados. Puede informar una incidencia con categoría, texto, ubicación y adjuntos; no puede cancelar la carga. La entrega registra hora/ubicación y el sistema rechaza duplicados aun tras reconexión.

## 11. Ubicación, privacidad y modo offline

### Política operacional

- Objetivo de cadencia: 10–15 segundos en movimiento y 30–60 segundos detenido, adaptando a batería, precisión, velocidad y red.
- Con carga activa, se solicita tracking de segundo plano si el permiso y el sistema operativo lo permiten, incluso si la interfaz se cerró. No se promete rastreo continuo después de force-quit, revocación de permisos, ahorro agresivo de batería o ausencia de señal.
- La app indica explícitamente: ubicación activa, aproximada, sin permiso, sin señal, pendiente de sincronización o desactualizada. El panel muestra última lectura y su antigüedad, no una falsa ubicación “en vivo”.
- La política de privacidad explica qué se recoge, propósito, acceso, retención, cómo termina con turno/carga y cómo contactar a la empresa. La configuración de retención se documenta antes de piloto.

### Offline

La app guarda en una base local: cambios de estado, evidencias por subir, incidencias y lecturas pendientes que cumplan política. Cada mutación crítica lleva un UUID de operación/idempotency key, orden lógico, resultado de servidor y política de reintento. Al volver la red sincroniza sin repetir entrega, documento o evento. “Hay Wi-Fi/datos” no equivale a “el servidor confirmó la operación”.

## 12. Panel administrativo

El dashboard muestra cargas activas/pendientes/retrasadas/completadas, conductores activos, vehículos disponibles, incidencias y un mapa de flota. El mapa permite abrir un vehículo y ver conductor, vehículo, carga, estado, última ubicación, antigüedad, velocidad aproximada, siguiente parada y ETA.

La gestión de cargas permite crear, editar, duplicar, buscar, filtrar, exportar dentro de los permisos, asignar, reasignar, cancelar y cerrar. Conductores y vehículos almacenan documentación, vencimientos y estado operativo. El diseño es profesional, claro y light-first: tabla y mapa densos pero legibles, estados con texto/ícono además de color, control grande en móvil y soporte de lector de pantalla, teclado y movimiento reducido.

## 13. Evidencia, documentos y links públicos

Dispatcher puede configurar por cliente/tipo de carga/carga si exige: nombre receptor, firma, BOL, POD, número de referencia, fecha/hora/GPS y fotografías. Fotografías deben poder ser opcionales porque algunos establecimientos no permiten teléfonos. Los archivos privados se almacenan con acceso autenticado, validación de tipo/tamaño, escaneo/controles de seguridad definidos por la implementación y trazabilidad de carga/consulta.

Un link público para broker/cliente es opcional. Usa un secreto opaco, guarda solo un verificador cuando sea posible, es de una carga, expira, puede revocarse, minimiza ubicación/ETA a lo acordado y excluye BOL, POD, fotos privadas, contactos privados y el resto de flota.

## 14. Arquitectura, despliegue y costo

### Arquitectura lógica

- **Web:** Next.js/React/TypeScript para dispatch y administración.
- **Móvil:** Flutter/Dart para Android/iOS, almacenamiento local durable y adaptadores nativos para GPS de segundo plano.
- **Datos:** PostgreSQL + PostGIS, autenticación, almacenamiento privado, RLS, eventos/auditoría y delivery de tiempo real privado.
- **Mapas:** MapLibre para visualizar; un adaptador de rutas intercambiable calcula distancias/ETAs. Google Routes puede ser la base de piloto con presupuestos/cotas; OSRM autoalojado es una alternativa posterior si se valida capacidad/costo. Los tiles también requieren un proveedor o una operación autoalojada evaluada.
- **Notificaciones:** Firebase Cloud Messaging y credenciales APNs para push. Son dependencias de plataforma, no un sustituto de autorización.

### Despliegue self-hosted first

Producción se despliega en Ubuntu Server mediante Dokploy y Docker Compose. La topología separa al menos: aplicación web/API, plano de datos/backend, proxy/TLS, volúmenes persistentes, red privada y servicios de monitoreo/backup. Studio administrativo, Postgres y servicios internos no se exponen directamente a Internet. Secretos se administran fuera de Git y se rotan mediante un runbook.

La opción inicial de bajo costo es Supabase autoalojado desde su distribución oficial Docker, no el stack local de CLI. Dokploy simplifica despliegue Docker/Compose y proxy, pero no reemplaza backups, actualizaciones, restauración, hardening, monitoreo ni capacidad. Un único servidor no da alta disponibilidad: antes del piloto se prueban restauración desde copia cifrada fuera del servidor, rollback de versión, alerta de disco/CPU/memoria, TLS, firewall/UFW, SSH limitado, política de actualizaciones y runbook de incidente.

### Dependencias externas que no se deben ocultar

- App Store/Google Play y sus políticas/credenciales.
- FCM/APNs para notificaciones.
- DNS/dominio/certificados y almacenamiento de backup externo.
- Proveedor de rutas y/o tiles, salvo que se opere y se pruebe una alternativa propia.
- Stripe u otro procesador solo cuando se habilite cobro posterior al piloto.

## 15. Seguridad y auditoría

- Autorización por tenant y rol en cada operación; RLS obligatoria sobre tablas expuestas.
- Service-role, claves privadas y secretos únicamente en servidor/gestor de secretos; nunca en Flutter, navegador, logs o repositorio.
- HTTPS/TLS, validación de entrada, límites de tasa, auditoría append-only, políticas de storage y URLs firmadas de vida limitada.
- Auditoría: actor/sesión, acción, recurso, empresa, fecha/hora, valores antes/después o revisión, origen/dispositivo cuando corresponda.
- Cuenta/conductor/vehículo se puede desactivar de inmediato. La invalidación debe surtir efecto en autorización, sesión y notificaciones futuras según política.
- Cyber Neo tiene autonomía para reparar hallazgos de seguridad dentro del repo, probarlos y documentar la corrección; la auditoría completa es un gate de piloto/store release.

## 16. Requisitos no funcionales

| Área | Requisito inicial |
|---|---|
| Rendimiento | Carga asignada y cambio de estado visibles rápidamente bajo red normal; la ubicación reciente se entrega con su timestamp de observación |
| Escala piloto | Al menos 50 vehículos activos por empresa en el mapa, sujeto a prueba de capacidad y límites explícitos de servidor/proveedor |
| Disponibilidad | Mostrar última información conocida y estado de desactualización; no inventar tiempo real durante una caída |
| Resiliencia | Reintentos idempotentes, colas persistentes, fallos de upload recuperables y backups restaurables |
| Accesibilidad | Contraste WCAG AA, 44px táctil mínimo, navegación por teclado en web, etiquetas semánticas y estados no basados solo en color |
| Idioma | English/Español desde el MVP, claves localizadas sin concatenación de texto |
| Observabilidad | Logs estructurados sin secretos, alertas de caída/recursos/backup, métricas de GPS/sync/errores y trazas de cambios críticos |

## 17. Métricas de éxito

- Porcentaje de cargas completadas en la app.
- Entregas con evidencia completa conforme a la configuración.
- Tiempo entre asignación y aparición para el conductor.
- Frescura de ubicación y tasa de sincronización exitosa.
- Cargas retrasadas, incidencias y tiempo de resolución.
- Reasignaciones y cambios de ruta que activan recálculo correctamente.
- Uso semanal de admin/dispatcher/driver.
- Coste mensual por organización/conductor/carga, uso de mapas/almacenamiento y margen por plan.
- Éxito de backup y tiempo de restauración probado.

## 18. Criterios de aceptación del MVP

### Asignación y permisos

- Un dispatcher autorizado puede asignar; la carga aparece en el conductor y se registra actor/hora.
- La app de conductor no contiene flujo de aceptación/rechazo/cancelación/reasignación.
- Una solicitud cross-tenant o cross-driver es denegada en servidor/RLS y se prueba automáticamente.

### Millas y precio

- Al guardar una cotización se muestran `empty_miles`, `loaded_miles`, `total_estimated_miles` y `quoted_usd_per_total_mile` con fuente y timestamp.
- Para una siguiente carga, `empty_miles` se calcula desde la última entrega planificada de la carga activa, no desde GPS actual.
- Un cambio de parada final/conductor/asignación produce una nueva revisión auditable y alerta a dispatch.

### Pickup, entrega y offline

- No se entrega una carga no recogida ni sin requisitos obligatorios configurados.
- Evidencia/entrega offline se sincroniza una sola vez aunque el cliente reintente la operación.
- La entrega guarda fecha/hora/ubicación disponibles, receptor/firma/documentos según configuración y queda revisable por administrador.

### Tracking y privacidad

- El panel identifica la última ubicación y su antigüedad, además de permiso/sync desactualizado cuando aplique.
- En dispositivos físicos de iOS y Android se prueba el caso de carga activa con app en segundo plano; el resultado real y limitaciones se registran.
- La app explica la finalidad del tracking y no afirma continuidad tras force-quit o permiso revocado.

### Despliegue piloto

- El stack se puede desplegar y revertir por Dokploy/Docker Compose sin secretos en Git.
- Existe backup cifrado fuera del servidor y una restauración ensayada antes de invitar pilotos.
- Cyber Neo, UI UX Pro Max y The Architect aprueban sus gates antes de expansión de piloto o solicitud de tienda.

## 19. Fases posteriores

**Fase 2:** múltiples paradas en UI, geofencing, alertas automáticas de retraso, portal de cliente ampliado, chat, exportaciones/reportes, firma avanzada y navegación integrada evaluada.

**Fase 3:** ELD/load boards, facturación/liquidaciones, optimización de rutas, mantenimiento, analítica avanzada, app cliente, despliegue HA/escala y evaluación de rutas especializadas para camiones.

## 20. Riesgos y mitigaciones iniciales

| Riesgo | Mitigación / gate |
|---|---|
| Rechazo de tienda por background GPS | Propósito claro, permisos graduales, tracker nativo, cuentas de revisión y pruebas físicas antes de envío |
| Batería/GPS impreciso | Cadencia adaptativa, precisión/frescura visible, manual de permisos y no prometer tracking imposible |
| Fuga entre carriers | RLS + pruebas de negación + auditoría Cyber Neo antes de piloto |
| Precio bajo no cubre uso | Métricas de coste por plan, cuota/retención, presupuesto de mapas y revisión de precios antes de venta pública |
| Servidor único cae o pierde datos | Backups externos cifrados, restore test, monitoreo, runbook y límites de piloto explícitos |
| Scope creep | Blueprint por fases; fuera del MVP no se añade sin decisión registrada |
| Dependencia de mapas | Adaptador de rutas/tiles, límites de uso y evaluación de alternativa autoalojada |

## 21. Referencias técnicas

- [Dokploy — documentación oficial](https://docs.dokploy.com/docs/core) y [instalación en Ubuntu](https://docs.dokploy.com/docs/core/installation).
- [Supabase self-hosting](https://supabase.com/docs/guides/self-hosting) y [despliegue Docker](https://supabase.com/docs/guides/self-hosting/docker). La documentación recalca que el operador asume mantenimiento, backups, recuperación, monitoreo, seguridad y escalado; el stack local de CLI no se expone como producción.
- [Supabase Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security) y [Realtime](https://supabase.com/docs/guides/realtime/subscribing-to-database-changes).
- [Android background location](https://developer.android.com/develop/sensors-and-location/location/permissions/background), [tipos de foreground service](https://developer.android.com/develop/background-work/services/fgs/service-types) y [Core Location en background](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background).
- [Firebase Cloud Messaging para Flutter](https://firebase.google.com/docs/cloud-messaging/flutter/get-started), [MapLibre GL JS](https://maplibre.org/maplibre-gl-js/docs/), [Google Routes matrix](https://developers.google.com/maps/documentation/routes/compute_route_matrix) y [OSRM](https://project-osrm.org/docs/).
- [Stripe subscriptions](https://docs.stripe.com/billing/subscriptions/overview), para la fase posterior de cobro web.
