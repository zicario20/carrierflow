/**
 * @vitest-environment jsdom
 */
import { cleanup, render, screen, within } from "@testing-library/react";
import { afterEach, describe, expect, test } from "vitest";

import { AdminShell, adminShellCss } from "../../src/app/layout";
import { operationalTokens } from "../../../../packages/design-tokens/src/tokens";

const localeExpectations = [
  {
    locale: "en",
    skipLinkName: "Skip to main content",
    navigationName: "Primary navigation",
    mainName: "Operations workspace",
    statusName: "Load status: On time",
    statusText: "Load status: On time",
    links: ["Operations", "Loads", "Drivers", "Vehicles", "Fleet"],
  },
  {
    locale: "es",
    skipLinkName: "Saltar al contenido principal",
    navigationName: "Navegación principal",
    mainName: "Espacio de trabajo de operaciones",
    statusName: "Estado de la carga: A tiempo",
    statusText: "Estado de la carga: A tiempo",
    links: ["Operaciones", "Cargas", "Conductores", "Vehículos", "Flota"],
  },
] as const;

afterEach(cleanup);

describe("AdminShell", () => {
  for (const expectation of localeExpectations) {
    test(`exposes named operational landmarks and navigation in ${expectation.locale}`, () => {
      render(<AdminShell locale={expectation.locale} />);

      const navigation = screen.getByRole("navigation", { name: expectation.navigationName });
      const skipLink = screen.getByRole("link", { name: expectation.skipLinkName });
      const links = expectation.links.map((name) => within(navigation).getByRole("link", { name }));

      expect(within(navigation).getAllByRole("link")).toHaveLength(5);
      expect(links).toHaveLength(5);
      const main = screen.getByRole("main", { name: expectation.mainName });
      expect(main.id).toBe("operations-main");
      expect(skipLink.getAttribute("href")).toBe(`#${main.id}`);
      expect(skipLink.compareDocumentPosition(navigation) & Node.DOCUMENT_POSITION_FOLLOWING).toBe(
        Node.DOCUMENT_POSITION_FOLLOWING,
      );
      skipLink.focus();
      expect(document.activeElement).toBe(skipLink);

      const status = screen.getByRole("status", { name: expectation.statusName });
      expect(status.textContent).toContain(expectation.statusText);
    });
  }

  test("uses shared tokenized 44 px targets and text for every navigation control", () => {
    render(<AdminShell locale="en" />);

    const navigation = screen.getByRole("navigation", { name: "Primary navigation" });
    const controls = within(navigation).getAllByRole("link");

    expect(controls).toHaveLength(5);
    for (const control of controls) {
      expect(control.classList.contains("carrierflow-control")).toBe(true);
      expect(control.textContent).not.toBe("");
    }
    expect(Number.parseInt(operationalTokens.interaction.minimumTarget, 10)).toBeGreaterThanOrEqual(44);
    expect(adminShellCss).toContain("min-inline-size: var(--cf-control-target)");
    expect(adminShellCss).toContain("min-block-size: var(--cf-control-target)");
    expect(adminShellCss).toMatch(
      /\.carrierflow-skip-link\s*\{[\s\S]*?min-block-size:\s*var\(--cf-control-target\)/,
    );
    expect(adminShellCss).toContain(".carrierflow-skip-link:focus-visible");
    expect(adminShellCss).toMatch(/\.carrierflow-skip-link\s*\{[^}]*cursor:\s*pointer/);
    expect(adminShellCss).toContain("transform: translateY(0)");
  });
});
