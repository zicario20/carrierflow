# ADR-001 — Despliegue self-hosted con Dokploy

**Estado:** Aceptado · **Fecha:** 2026-08-27 · **Decisor:** Producto/Arquitectura

## Contexto

CarrierFlow comienza como piloto privado y debe minimizar suscripciones recurrentes. El propietario planea operar un Ubuntu Server propio. La plataforma conserva datos de ubicación, documentación y operación de múltiples carriers, por lo que una solución barata sin recuperación, aislamiento o mantenimiento no es aceptable.

## Decisión

Usar **Dokploy autoalojado sobre Ubuntu Server** como control de despliegue de Docker/Docker Compose. El entorno productivo se diseña self-hosted first:

- aplicación web/API CarrierFlow;
- plano de datos autoalojado (PostgreSQL/PostGIS y los servicios de autenticación, almacenamiento y tiempo real seleccionados);
- proxy/TLS de Dokploy;
- redes privadas para datos/servicios internos;
- volúmenes persistentes declarados;
- secretos fuera de Git;
- monitorización y backup cifrado fuera del servidor.

Supabase autoalojado mediante la distribución Docker oficial es la ruta base para conservar Auth, Storage, RLS y Realtime, siempre con versión fijada y procedimiento de actualización. El stack `supabase start`/CLI se reserva para desarrollo y pruebas locales; no se expone como producción.

## Consecuencias

### Positivas

- Reduce el coste fijo de hosting y permite control de datos/operación.
- Mantiene una ruta de migración a infraestructura más robusta sin cambiar el contrato de aplicación.
- Dokploy centraliza deploy, dominios y proxy para los servicios Docker.

### Costes y riesgos aceptados

- Un solo servidor no es alta disponibilidad. Una caída de host o red puede interrumpir todo el servicio.
- El operador es responsable de parchear Ubuntu/Docker/containers, administrar Postgres, vigilar recursos, configurar seguridad y ejecutar recuperación ante desastre.
- Un backup que nunca se restauró no cuenta como backup. Se exige prueba de restore antes de cualquier piloto y recurrentemente según runbook.
- FCM/APNs, dominio/DNS, almacenamiento de backup y, potencialmente, routes/tiles mantienen costes o cuentas externas. No se maquillan como autoalojados.

## Controles obligatorios antes del piloto

1. Ubuntu LTS compatible, Docker actualizado, acceso SSH con llaves, usuario sin privilegios cotidianos, firewall/UFW y acceso administrativo restringido.
2. Dokploy, dominios y TLS funcionando; no publicar Postgres, Studio ni paneles internos a Internet.
3. Secrets inyectados por el entorno de despliegue, sin `.env` productivo ni claves privadas versionadas.
4. Volúmenes persistentes identificados; backup cifrado fuera del host con retención documentada.
5. Restauración completa ensayada en entorno aislado con resultado, duración y responsable registrados.
6. Actualización versionada y rollback probado para aplicación y plano Supabase/DB; las migraciones son compatibles con rollback o tienen recuperación explícita.
7. Monitoreo de disponibilidad, disco, memoria, CPU, errores, jobs de backup y expiración TLS; alertas con propietario operativo.
8. Cyber Neo revisa la configuración/despliegue y puede corregir fallos dentro del repositorio, dejando informe de corrección y riesgo residual.

## Límites

Este ADR no elige aún tamaño de servidor, proveedor DNS/backup, RPO/RTO ni periodo de retención. Esas cifras se cierran con una prueba de carga, presupuesto y perfil del piloto antes de abrir invitaciones. Tampoco habilita cobros reales ni cambia las políticas de Apple/Google.

## Referencias

- [Dokploy core](https://docs.dokploy.com/docs/core) y [instalación](https://docs.dokploy.com/docs/core/installation).
- [Supabase self-hosting](https://supabase.com/docs/guides/self-hosting) y [Docker](https://supabase.com/docs/guides/self-hosting/docker).
