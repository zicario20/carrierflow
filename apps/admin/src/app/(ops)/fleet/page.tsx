import { operationalTokens } from "../../../../../../packages/design-tokens/src/tokens";

export default function FleetPage() {
  return (
    <section aria-labelledby="fleet-heading">
      <h1 id="fleet-heading">Fleet</h1>
      <section
        aria-labelledby="fleet-setup-heading"
        style={{
          backgroundColor: operationalTokens.color.surface,
          border: `1px solid ${operationalTokens.color.border}`,
          borderRadius: operationalTokens.radius.surface,
          marginBlockStart: operationalTokens.spacing.comfortable,
          maxWidth: "42rem",
          padding: operationalTokens.spacing.comfortable,
        }}
      >
        <h2 id="fleet-setup-heading">Fleet setup</h2>
        <p>No drivers or vehicles are available yet.</p>
        <p>
          Dispatcher-managed fleet controls will appear here once the authenticated operations
          workflow is connected.
        </p>
        <a className="carrierflow-control" href="/">
          Return to operations overview
        </a>
      </section>
    </section>
  );
}
