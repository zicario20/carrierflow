# CarrierFlow private-pilot release gates

This runbook is a release checklist, not a deployment authorization. CarrierFlow is a single-host private pilot: it is not highly available and this document does not set an RTO/RPO or certify a disaster-recovery target.

## Dokploy and host preparation

Before creating the Dokploy application, the operator must complete all of the following:

- Use a supported, patched Ubuntu host with SSH keys, UFW, least-privilege operator access, and no public database, Studio, admin, worker, or monitoring port. Only the TLS proxy may bind 80/443.
- Pin and review every container image in Dokploy. The Compose file intentionally requires image values rather than storing image tags or registry credentials in Git.
- Configure non-versioned, per-service environment files in Dokploy. The admin file alone receives `SUPABASE_SERVICE_ROLE_KEY`, `PUSH_TOKEN_ENCRYPTION_KEY`, `FCM_SERVICE_ACCOUNT_JSON`, and `PUSH_WORKER_SECRET`; the dispatcher file receives only `PUSH_WORKER_SECRET` and its interval; database, Supabase API, Storage, and monitoring files contain only the variables required by their own service. Do not place values in `.env.example`, Compose, GitHub Actions, client bundles, logs, or issue text.
- Set `NEXT_PUBLIC_SUPABASE_URL` to the TLS `/supabase` endpoint and `SUPABASE_URL` to the private service endpoint. Do not make a raw Supabase port public.
- Apply a host/firewall egress allowlist: only the admin workload's `egress_controlled` network may use outbound TLS for FCM (`fcm.googleapis.com` and required Google token endpoints) and explicitly approved routing/provider hosts. The TLS proxy's certificate issuance traffic is separately necessary. Do not give the dispatcher, database, Supabase API, Storage, or monitoring services generic internet egress.
- Deploy and verify all migrations through `0031_entitlements_retention.sql` before inviting users. Do not enable FCM delivery until server-only credentials, the dispatch secret, and invalid-token handling have been checked on real devices.
- Review image/Supabase/Dokploy release notes, take a backup, document the rollback image/version, then deploy through Dokploy. The private `push-dispatcher` is the only component that calls `/api/internal/push/dispatch`; it reaches it over `app_private` and sends the operator secret only as an HTTP header.

Render the topology with values only in a disposable operator shell or Dokploy preview. A successful render proves syntax and port/network declarations only; it does not start containers or test credentials.

```powershell
docker compose -f infra/dokploy/docker-compose.production.yml config
```

## Backup and restore evidence

`scripts/verify-local-restore.mjs` never restores data. It accepts only `--dry-run`, an explicitly named disposable directory, its marker, and fixture metadata inside that directory. It performs no database, object-store, network, Docker, Dokploy, production, or off-server action.

For a local verifier check, create a newly disposable directory outside the repository, add the required `.carrierflow-disposable-restore` marker and the approved local fixture metadata, then run:

```powershell
node scripts/verify-local-restore.mjs --dry-run --directory <absolute-disposable-directory> --metadata <absolute-fixture-metadata-path>
```

The required pilot gate is separate: restore an encrypted Postgres backup and private object evidence to a non-production target from a backup stored outside the host, verify the resulting data and access controls, record the elapsed time and retention result, then destroy that non-production restore according to the approved operations policy. This repository neither performs nor claims that test.

## Pilot approval checklist

- [ ] An external GitHub Actions pull-request run passed the separated typecheck, lint, unit, pgTAP, admin build, critical Playwright, and Flutter jobs.
- [ ] Two isolated companies prove cross-tenant denial, mandatory assignment/state ordering, route revision auditing, configured evidence enforcement, opaque-link expiry/revocation, and entitlement capacity under concurrent activation.
- [ ] Privacy review confirms seven-day raw GPS retention, current-location clearing, audit minimization, private evidence access, public-link projection, and no checkout or charge in the private pilot.
- [ ] Physical Android and iOS checks cover sign-in/sign-out, permission denial/approximate/stale location states, best-effort background behavior and force-quit disclosure, offline replay, camera/evidence, external maps, FCM permission/token/invalid-token flow, and English/Spanish accessibility.
- [ ] UI/UX review verifies keyboard focus, screen-reader names, non-color-only status, contrast, 44px controls, reduced motion, loading/error/retry, and English/Spanish operational copy.
- [ ] Cyber Neo release audit covers dependencies, RLS/direct-DML denial, service-role and FCM secret boundaries, push worker isolation, public links, storage, logs, and host/network exposure; release blockers are remediated or explicitly accepted by the owner.
- [ ] Host monitoring and alerts cover CPU/RAM/disk, database, backup, queues, stale GPS, notification failures, routing cost, and unauthorised access signals. Capacity, cost, an approved off-host encrypted backup location, and recovery objectives are recorded by the operator.
- [ ] Store-review accounts/invitations and privacy disclosures are ready. Store submission and paid billing remain blocked until official Apple/Google approval and a separate billing decision.
