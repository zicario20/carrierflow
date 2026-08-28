---
description: Flutter driver, offline and background-location conventions
paths:
  - "apps/driver/**"
---

- Show current load before next load. Never expose acceptance/rejection.
- Persist mutations/evidence before network send with client_mutation_id and ordered retries.
- Use native Core Location/Fused Location and Android foreground service configuration for active-load background tracking; workmanager is recovery only.
- Represent permission denied, approximate, stale, battery restriction and force-quit as degraded states.
- Do not promise heavy-vehicle-safe external navigation. Open Google/Apple Maps only as an external handoff.
- Verify background location and push on physical iOS and Android devices before pilot.

