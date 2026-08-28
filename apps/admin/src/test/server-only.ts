// Vitest runs outside Next.js's react-server condition. This test-only shim
// retains production's server-only import while allowing server modules to be
// exercised in the Node test environment.
export {};
