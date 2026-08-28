import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, test } from "vitest";

import { AdminShell, adminShellCss } from "../../src/app/layout";
import { operationalTokens } from "../../../../packages/design-tokens/src/tokens";

describe("AdminShell", () => {
  test("renders the complete English operational navigation", () => {
    const markup = renderToStaticMarkup(<AdminShell locale="en" />);

    expect(markup).toContain("Operations");
    expect(markup).toContain("Loads");
    expect(markup).toContain("Drivers");
    expect(markup).toContain("Vehicles");
    expect(markup).toContain("On time");
  });

  test("renders the complete Spanish operational navigation", () => {
    const markup = renderToStaticMarkup(<AdminShell locale="es" />);

    expect(markup).toContain("Operaciones");
    expect(markup).toContain("Cargas");
    expect(markup).toContain("Conductores");
    expect(markup).toContain("Vehículos");
    expect(markup).toContain("A tiempo");
  });

  test("exposes a labelled main landmark and textual operational status", () => {
    const markup = renderToStaticMarkup(<AdminShell locale="en" />);

    expect(markup).toMatch(/<main aria-label="Operations workspace"(?:\s|>)/);
    expect(markup).toContain('role="status"');
    expect(markup).toContain("Load status:");
    expect(markup).toContain("On time");
  });

  test("uses shared tokenized 44 px targets for every navigation control", () => {
    const markup = renderToStaticMarkup(<AdminShell locale="en" />);

    expect(operationalTokens.interaction.minimumTarget).toBe("44px");
    expect(markup.match(/class="carrierflow-control"/g)).toHaveLength(4);
    expect(markup).toContain("--cf-control-target:44px");
    expect(adminShellCss).toContain("min-inline-size: var(--cf-control-target)");
    expect(adminShellCss).toContain("min-block-size: var(--cf-control-target)");
  });
});
