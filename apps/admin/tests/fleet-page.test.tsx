/**
 * @vitest-environment jsdom
 */
import { cleanup, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, test } from "vitest";

import { FleetContent } from "../src/app/(ops)/fleet/page";

afterEach(cleanup);

describe("FleetPage", () => {
  test.each([
    {
      emptyState: "No drivers or vehicles are available yet.",
      heading: "Fleet",
      locale: "en" as const,
      returnLabel: "Return to operations overview",
      setup: "Fleet setup",
    },
    {
      emptyState: "Todavía no hay conductores ni vehículos disponibles.",
      heading: "Flota",
      locale: "es" as const,
      returnLabel: "Volver al resumen de operaciones",
      setup: "Configuración de flota",
    },
  ])("offers a semantic $locale empty fleet state without promising disconnected mutations", (copy) => {
    render(<FleetContent locale={copy.locale} />);

    expect(screen.getByRole("heading", { level: 1, name: copy.heading })).toBeTruthy();
    const setup = screen.getByRole("region", { name: copy.setup });
    expect(setup).toBeTruthy();
    expect(setup.getAttribute("style")).toContain("border-radius: 12px");
    expect(screen.getByText(copy.emptyState)).toBeTruthy();

    const returnLink = screen.getByRole("link", { name: copy.returnLabel });
    expect(returnLink.getAttribute("href")).toBe("/");
  });
});
