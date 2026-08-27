---
type: "query"
date: "2026-08-27T20:53:39.771739+00:00"
question: "How do mandatory assignment, mileage revisions, and tenant security constrain the private pilot?"
contributor: "graphify"
outcome: "useful"
source_nodes: ["agents_mandatory_dispatch_assignment", "blueprints_carrierflow_blueprint_mileage_revision_contract", "agents_tenant_authorization_boundary"]
---

# Q: How do mandatory assignment, mileage revisions, and tenant security constrain the private pilot?

## Answer

Mandatory dispatch is server-authorized, rate estimates remain separately versioned from the active load’s final stop, and every organization boundary is enforced by RLS before pilot release.

## Outcome

- Signal: useful

## Source Nodes

- agents_mandatory_dispatch_assignment
- blueprints_carrierflow_blueprint_mileage_revision_contract
- agents_tenant_authorization_boundary