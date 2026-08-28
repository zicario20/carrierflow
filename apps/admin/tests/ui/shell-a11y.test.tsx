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
    navigationName: "Primary navigation",
    mainName: "Operations workspace",
    statusName: "Load status: On time",
    statusText: "Load status: On time",
    links: ["Operations", "Loads", "Drivers", "Vehicles"],
  },
  {
    locale: "es",
    navigationName: "Navegación principal",
    mainName: "Espacio de trabajo de operaciones",
    statusName: "Estado de la carga: A tiempo",
    statusText: "Estado de la carga: A tiempo",
    links: ["Operaciones", "Cargas", "Conductores", "Vehículos"],
  },
] as const;

afterEach(cleanup);

describe("AdminShell", () => {
  for (const expectation of localeExpectations) {
    test(`exposes named operational landmarks and navigation in ${expectation.locale}`, () => {
      render(<AdminShell locale={expectation.locale} />);

      const navigation = screen.getByRole("navigation", { name: expectation.navigationName });
      const links = expectation.links.map((name) => within(navigation).getByRole("link", { name }));

      expect(within(navigation).getAllByRole("link")).toHaveLength(4);
      expect(links).toHaveLength(4);
      expect(screen.getByRole("main", { name: expectation.mainName })).toBeTruthy();

      const status = screen.getByRole("status", { name: expectation.statusName });
      expect(status.textContent).toContain(expectation.statusText);
    });
  }

  test("uses shared tokenized 44 px targets and text for every navigation control", () => {
    render(<AdminShell locale="en" />);

    const navigation = screen.getByRole("navigation", { name: "Primary navigation" });
    const controls = within(navigation).getAllByRole("link");

    expect(controls).toHaveLength(4);
    for (const control of controls) {
      expect(control.classList.contains("carrierflow-control")).toBe(true);
      expect(control.textContent).not.toBe("");
    }
    expect(Number.parseInt(operationalTokens.interaction.minimumTarget, 10)).toBeGreaterThanOrEqual(44);
    expect(adminShellCss).toContain("min-inline-size: var(--cf-control-target)");
    expect(adminShellCss).toContain("min-block-size: var(--cf-control-target)");
  });
});
