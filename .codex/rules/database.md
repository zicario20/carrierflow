---
description: Supabase schema, RLS, migration, audit and storage conventions
paths:
  - "supabase/**"
  - "apps/admin/src/server/**"
---

- Add forward-only SQL migrations; never edit a migration that has run.
- Every commercial table has company_id and RLS. Derive tenant from auth membership.
- Use SECURITY DEFINER functions only with fixed search_path, explicit authorization and tests.
- Service-role use is server-only and no RLS replacement.
- Mutations write audit events in the same transaction.
- Use private Storage paths prefixed by company; signed URLs follow authorization.
- Test tenant isolation with pgTAP before merging.

