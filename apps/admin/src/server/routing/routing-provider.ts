import "server-only";

import type { RoutingProvider } from "@carrierflow/routing-contract/index";

/**
 * Routing implementations are injected only from trusted server code. Browser
 * bundles must never receive provider credentials or call a routing provider
 * directly. Distances are operational estimates, not truck-safe directions.
 */
export type ServerRoutingProvider = RoutingProvider;
