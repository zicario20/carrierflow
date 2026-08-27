---
description: Security remediation and secret-handling rules
paths:
  - "apps/**"
  - "supabase/**"
  - "infra/**"
  - ".github/**"
---

- Validate inputs at every HTTP/RPC boundary and return typed safe errors.
- Never log, commit, echo or pass credentials to client code.
- Public tracking tokens are opaque, hashed at rest, scoped, expiring and revocable.
- Rate-limit authentication, public tokens and uploads.
- Cyber Neo may remediate scoped repository findings and must record test evidence and notification.
- Escalate destructive data changes, credential rotation, paid/external changes and production access.

