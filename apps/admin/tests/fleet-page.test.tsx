/**
 * @vitest-environment jsdom
 */
import { cleanup, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, test } from "vitest";

import FleetPage from "../src/app/(ops)/fleet/page";

afterEach(cleanup);

describe("FleetPage", () => {
  test("offers a semantic empty fleet state without promising disconnected mutations", () => {
    render(<FleetPage />);

    expect(screen.getByRole("heading", { level: 1, name: "Fleet" })).toBeTruthy();
    const setup = screen.getByRole("region", { name: "Fleet setup" });
    expect(setup).toBeTruthy();
    expect(setup.getAttribute("style")).toContain("border-radius: 12px");
    expect(screen.getByText("No drivers or vehicles are available yet.")).toBeTruthy();

    const returnLink = screen.getByRole("link", { name: "Return to operations overview" });
    expect(returnLink.getAttribute("href")).toBe("/");
  });
});
