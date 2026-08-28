/**
 * @vitest-environment jsdom
 */
import { cleanup, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, test } from "vitest";

import {
  PlanSettingsContent,
  resolvePlanSettingsPageState,
} from "../src/app/(ops)/settings/plan/page";
import { PlanSettingsLoadingContent } from "../src/app/(ops)/settings/plan/loading";

afterEach(cleanup);

const entitlement = {
  activeDriverCount: 4,
  availableDriverSlots: 6,
  driverCapacity: 10,
  monthlyPriceUsd: 20,
  planCode: "starter" as const,
  trialEndsAt: "2026-09-04T12:00:00.000Z",
  trialStartedAt: "2026-08-28T12:00:00.000Z",
  trialState: "active" as const,
};

describe("PlanSettingsContent", () => {
  test.each([
    {
      heading: "Plan and privacy",
      locale: "en" as const,
      pilot: "Private pilot — billing is not enabled.",
      price: "$20 USD / month",
      trial: "7-day trial",
    },
    {
      heading: "Plan y privacidad",
      locale: "es" as const,
      pilot: "Piloto privado: la facturación no está habilitada.",
      price: "$20 USD / mes",
      trial: "Prueba de 7 días",
    },
  ])("renders accessible $locale pilot capacity without a checkout control", (copy) => {
    render(<PlanSettingsContent state={{ entitlement, kind: "ready" }} locale={copy.locale} />);

    expect(screen.getByRole("heading", { level: 1, name: copy.heading })).toBeTruthy();
    expect(screen.getByText(copy.pilot)).toBeTruthy();
    expect(screen.getByText(copy.price)).toBeTruthy();
    expect(screen.getByText(copy.trial)).toBeTruthy();
    expect(screen.getByText("4 / 10")).toBeTruthy();
    expect(screen.queryByRole("button")).toBeNull();
    expect(screen.queryByRole("link", { name: /checkout|pagar/i })).toBeNull();
  });

  test.each([
    { locale: "en" as const, ownerOnly: "Plan details are available only to the active company owner." },
    { locale: "es" as const, ownerOnly: "Los detalles del plan solo están disponibles para el propietario activo de la empresa." },
  ])("shows an owner-only semantic $locale state only after an authorization denial", (copy) => {
    render(<PlanSettingsContent state={{ kind: "owner_only" }} locale={copy.locale} />);

    expect(screen.getByRole("status").textContent).toContain(copy.ownerOnly);
  });

  test.each([
    {
      locale: "en" as const,
      retry: "Retry plan settings",
      unavailable: "Plan details are temporarily unavailable. Try again or contact CarrierFlow support.",
    },
    {
      locale: "es" as const,
      retry: "Reintentar configuración del plan",
      unavailable: "Los detalles del plan no están disponibles temporalmente. Inténtalo de nuevo o contacta al soporte de CarrierFlow.",
    },
  ])("renders a recoverable $locale alert for an active owner when plan data is unavailable", (copy) => {
    render(<PlanSettingsContent state={{ kind: "unavailable" }} locale={copy.locale} />);

    expect(screen.getByRole("alert").textContent).toContain(copy.unavailable);
    expect(screen.getByRole("link", { name: copy.retry }).getAttribute("href")).toBe("/settings/plan");
    expect(screen.queryByText(/only to the active company owner|solo están disponibles para el propietario activo/i)).toBeNull();
  });

  test("maps only an actual forbidden result to owner-only and maps null or recoverable errors to unavailable", () => {
    expect(resolvePlanSettingsPageState(null)).toEqual({ kind: "unavailable" });
    expect(resolvePlanSettingsPageState({
      ok: false,
      error: { code: "forbidden", message: "You do not have permission to perform this action." },
    })).toEqual({ kind: "owner_only" });
    expect(resolvePlanSettingsPageState({
      ok: false,
      error: { code: "validation", message: "Pilot plan settings could not be loaded." },
    })).toEqual({ kind: "unavailable" });
  });

  test.each([
    { locale: "en" as const, loading: "Loading plan settings…" },
    { locale: "es" as const, loading: "Cargando configuración del plan…" },
  ])("announces a localized $locale loading boundary instead of an access state", (copy) => {
    render(<PlanSettingsLoadingContent locale={copy.locale} />);

    expect(screen.getByRole("status").textContent).toContain(copy.loading);
    expect(screen.queryByText(/only to the active company owner|solo están disponibles para el propietario activo/i)).toBeNull();
  });
});
