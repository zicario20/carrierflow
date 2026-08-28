/** @vitest-environment jsdom */
import { createElement } from "react";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, test, vi } from "vitest";

const serverStubs = vi.hoisted(() => ({
  createSupabaseServerClient: vi.fn(),
  getAuthorizedCurrentLocation: vi.fn(),
  getAuthenticatedDispatchContext: vi.fn(),
  getRequestLocale: vi.fn(),
}));

vi.mock("../src/components/map/current-location-map", () => ({ CurrentLocationMap: ({ location }: { location: { latitude: number; longitude: number } }) => createElement("div", { "data-location": `${location.latitude},${location.longitude}`, "data-testid": "current-location-map" }) }));
vi.mock("../src/lib/supabase/server", () => ({ createSupabaseServerClient: serverStubs.createSupabaseServerClient }));
vi.mock("../src/server/dispatch/dispatch-context", () => ({ getAuthenticatedDispatchContext: serverStubs.getAuthenticatedDispatchContext }));
vi.mock("../src/server/tracking/current-location-service", () => ({ getAuthorizedCurrentLocation: serverStubs.getAuthorizedCurrentLocation }));
vi.mock("../src/i18n/request-locale", () => ({ getRequestLocale: serverStubs.getRequestLocale }));

import { LoadProposalForm } from "../src/components/loads/load-form";
import { LoadDispatchControls } from "../src/components/loads/load-dispatch-controls";
import OperationsMapPage, { OperationsMapContent } from "../src/app/(ops)/map/page";
import LoadDetailPage from "../src/app/(ops)/loads/[loadId]/page";
import type { ProposalActionState } from "../src/app/(ops)/loads/new/action-state";
import type { DispatchActionState } from "../src/app/(ops)/loads/[loadId]/action-state";

afterEach(() => { cleanup(); vi.clearAllMocks(); });
const estimate = { emptyMiles: "12.500", loadedMiles: "87.500", quoteUsd: "250.00", quoteUsdPerTotalMile: "2.5000000000000000", totalMiles: "100.000" } as const;
const driver = { companyId: "c", displayName: "Avery", id: "d", membershipId: "m", status: "active" } as const;
const vehicle = { capacityLbs: 1, companyId: "c", id: "v", status: "active", type: "cargo_van", unitNumber: "V-1" } as const;

function dispatchControls(
  assignAction: (state: DispatchActionState, formData: FormData) => Promise<DispatchActionState>,
  cancelAction: (state: DispatchActionState, formData: FormData) => Promise<DispatchActionState>,
  locale: "en" | "es" = "en",
) {
  return createElement(LoadDispatchControls, { assignAction, cancelAction, currentStatus: "assigned", drivers: [driver], loadId: "load", locale, vehicles: [vehicle] });
}

function completeProposal(locale: "en" | "es") {
  fireEvent.change(screen.getByLabelText(locale === "en" ? "Load number" : "Número de carga"), { target: { value: "LOAD-1" } });
  fireEvent.change(screen.getByLabelText(locale === "en" ? "Quoted amount (USD)" : "Monto cotizado (USD)"), { target: { value: "250.00" } });
  fireEvent.change(screen.getByLabelText(locale === "en" ? "Pickup stop" : "Parada de recogida"), { target: { value: "Pickup" } });
  fireEvent.change(screen.getByLabelText(locale === "en" ? "Delivery stop" : "Parada de entrega"), { target: { value: "Delivery" } });
}

describe("dispatch proposal flow", () => {
  test("renders only a server revision's separate exact mileage and rate", () => {
    render(createElement(LoadProposalForm, { action: async (): Promise<ProposalActionState> => ({ status: "idle" }), initialState: { routeEstimate: estimate, status: "success" }, locale: "en" }));
    expect(screen.getByText("12.500 mi")).toBeTruthy(); expect(screen.getByText("87.500 mi")).toBeTruthy(); expect(screen.getByText("100.000 mi")).toBeTruthy();
    expect(screen.getByText("$2.5000000000000000 / total mi")).toBeTruthy(); expect(screen.queryByText("0.000 mi")).toBeNull();
  });
  test("submits one Spanish proposal intent, announces assignment required, and never sends GPS/miles/role", async () => {
    let sent: FormData | undefined;
    const proposalAction = vi.fn(async (_state: ProposalActionState, formData: FormData): Promise<ProposalActionState> => { sent = formData; return { loadId: "load", routeStatus: "assignment_required", status: "success" }; });
    render(createElement(LoadProposalForm, { action: proposalAction, initialState: { status: "idle" }, locale: "es" }));
    fireEvent.change(screen.getByLabelText("Número de carga"), { target: { value: "LOAD-1" } }); fireEvent.change(screen.getByLabelText("Monto cotizado (USD)"), { target: { value: "250.00" } }); fireEvent.change(screen.getByLabelText("Parada de recogida"), { target: { value: "Pickup" } }); fireEvent.change(screen.getByLabelText("Parada de entrega"), { target: { value: "Delivery" } });
    await waitFor(() => expect((screen.getByRole("button", { name: "Guardar propuesta de carga" }) as HTMLButtonElement).disabled).toBe(false));
    await act(async () => { fireEvent.submit(screen.getByRole("button", { name: "Guardar propuesta de carga" }).closest("form")!); });
    await waitFor(() => expect(screen.getByText(/Asigna un conductor y vehículo activos/i)).toBeTruthy());
    expect(screen.getByRole("link", { name: "Abrir asignación de despacho" }).getAttribute("href")).toBe("/loads/load");
    expect(sent?.get("intentKey")).toMatch(/^[0-9a-f-]{36}$/i); expect(JSON.stringify([...(sent?.entries() ?? [])])).not.toMatch(/gps|mile|actorRole|driverId/i);
  });
  test("validates blur feedback and keeps route-pending copy honest in Spanish", () => {
    render(createElement(LoadProposalForm, { action: async (): Promise<ProposalActionState> => ({ status: "idle" }), initialState: { status: "pending" }, locale: "es" }));
    const quote = screen.getByLabelText("Monto cotizado (USD)"); fireEvent.change(quote, { target: { value: "0" } }); fireEvent.blur(quote);
    expect(screen.getByText("Ingresa un monto cotizado en USD mayor que cero.")).toBeTruthy(); expect(screen.getByText(/no se inventaron millas/i)).toBeTruthy();
  });
  test("uses a native destructive cancellation dialog that closes on Escape and returns focus", async () => {
    const assignAction = vi.fn(async (_state: DispatchActionState, _formData: FormData): Promise<DispatchActionState> => ({ message: "Route estimate ready.", routeEstimate: estimate, routeStatus: "ready", status: "success" }));
    const cancelAction = vi.fn(async (_state: DispatchActionState, _formData: FormData): Promise<DispatchActionState> => ({ message: "Load cancelled and audited.", status: "success" }));
    render(dispatchControls(assignAction, cancelAction));
    await waitFor(() => expect((screen.getByRole("button", { name: "Assign mandatory load" }) as HTMLButtonElement).disabled).toBe(false));
    fireEvent.change(screen.getByLabelText("Driver"), { target: { value: "d" } }); fireEvent.change(screen.getByLabelText("Vehicle"), { target: { value: "v" } });
    await act(async () => { fireEvent.submit(screen.getByRole("button", { name: "Assign mandatory load" }).closest("form")!); });
    await waitFor(() => expect(screen.getByText("Route estimate ready.")).toBeTruthy()); expect(screen.getByText("100.000 mi")).toBeTruthy();
    const cancel = screen.getByRole("button", { name: "Cancel load" });
    fireEvent.click(cancel);
    const dialog = screen.getByRole("dialog");
    const confirm = screen.getByRole("button", { name: "Confirm cancellation" });
    expect(dialog.hasAttribute("open")).toBe(true); expect(confirm.className).toContain("carrierflow-destructive-control"); expect(document.activeElement).toBe(confirm); expect(cancelAction).not.toHaveBeenCalled();
    fireEvent(dialog, new Event("cancel", { cancelable: true }));
    await waitFor(() => expect(dialog.hasAttribute("open")).toBe(false));
    expect(document.activeElement).toBe(cancel);
    expect(screen.queryByRole("button", { name: /accept|reject/i })).toBeNull();
  });
  test("keeps a proposal intent across a failed retry, rotates it only after success, and announces English errors", async () => {
    const keys: string[] = [];
    let attempts = 0;
    const action = vi.fn(async (_state: ProposalActionState, formData: FormData): Promise<ProposalActionState> => {
      keys.push(String(formData.get("intentKey"))); attempts += 1;
      return attempts === 1 ? { message: "Proposal rejected by the server.", status: "error" } : attempts === 2 ? { loadId: "load", routeStatus: "assignment_required", status: "success" } : { message: "Proposal rejected by the server.", status: "error" };
    });
    render(createElement(LoadProposalForm, { action, initialState: { status: "idle" }, locale: "en" }));
    completeProposal("en");
    await waitFor(() => expect((screen.getByRole("button", { name: "Save load proposal" }) as HTMLButtonElement).disabled).toBe(false));
    const form = screen.getByRole("button", { name: "Save load proposal" }).closest("form")!;
    await act(async () => { fireEvent.submit(form); });
    await waitFor(() => expect(screen.getByRole("alert").textContent).toContain("Proposal rejected by the server."));
    await act(async () => { fireEvent.submit(form); });
    await waitFor(() => expect(screen.getByRole("link", { name: "Open dispatch assignment" })).toBeTruthy());
    await waitFor(() => expect((form.querySelector('input[name="intentKey"]') as HTMLInputElement).value).not.toBe(keys[0]));
    await act(async () => { fireEvent.submit(form); });
    await waitFor(() => expect(keys).toHaveLength(3));
    expect(keys[1]).toBe(keys[0]); expect(keys[2]).not.toBe(keys[0]);
  });
  test("uses busy and disabled states during a pending assignment and announces Spanish forbidden results", async () => {
    let resolveAssignment!: (state: DispatchActionState) => void;
    const assignAction = vi.fn(() => new Promise<DispatchActionState>((resolve) => { resolveAssignment = resolve; }));
    const cancelAction = vi.fn(async (): Promise<DispatchActionState> => ({ message: "No tienes permiso para realizar esta acción.", status: "forbidden" }));
    render(dispatchControls(assignAction, cancelAction, "es"));
    await waitFor(() => expect((screen.getByRole("button", { name: "Asignar carga obligatoria" }) as HTMLButtonElement).disabled).toBe(false));
    fireEvent.change(screen.getByLabelText("Conductor"), { target: { value: "d" } }); fireEvent.change(screen.getByLabelText("Vehículo"), { target: { value: "v" } });
    const assignmentForm = screen.getByRole("button", { name: "Asignar carga obligatoria" }).closest("form")!;
    fireEvent.submit(assignmentForm);
    await waitFor(() => expect(assignmentForm.getAttribute("aria-busy")).toBe("true"));
    expect(screen.getByRole("button", { name: "Guardando…" })).toHaveProperty("disabled", true);
    await act(async () => { resolveAssignment({ message: "La asignación obligatoria fue rechazada por el servidor.", status: "error" }); });
    await waitFor(() => expect(screen.getByRole("alert").textContent).toContain("La asignación obligatoria fue rechazada por el servidor."));
    fireEvent.click(screen.getByRole("button", { name: "Cancelar carga" }));
    await act(async () => { fireEvent.submit(screen.getByRole("button", { name: "Confirmar cancelación" }).closest("form")!); });
    await waitFor(() => expect(screen.getByText("No tienes permiso para realizar esta acción.").getAttribute("role")).toBe("alert"));
  });
  test("omits dispatch controls when the server denies a driver management context", async () => {
    serverStubs.getRequestLocale.mockResolvedValue("en");
    serverStubs.getAuthenticatedDispatchContext.mockResolvedValue(null);
    serverStubs.createSupabaseServerClient.mockResolvedValue({
      from: () => ({ select: () => ({ eq: () => ({ maybeSingle: async () => ({ data: { load_evidence_requirements: [], load_incidents: [], load_number: "LOAD-1", load_stops: [], operational_status: "assigned" }, error: null }) }) }) }),
    });
    const page = await LoadDetailPage({ params: Promise.resolve({ loadId: "load" }) });
    render(page);
    expect(screen.queryByRole("button", { name: /assign mandatory load|cancel load/i })).toBeNull();
  });
  test("renders bilingual map fallback/current surface without history or track points", () => {
    const { rerender } = render(createElement(OperationsMapContent, { currentLocation: null, locale: "en" }));
    expect(screen.getByText(/No authorized current location/i)).toBeTruthy(); expect(screen.queryByTestId("current-location-map")).toBeNull(); expect(screen.queryByText(/history|track points/i)).toBeNull();
    rerender(createElement(OperationsMapContent, { currentLocation: { driverLabel: "Avery", latitude: 41.8781, longitude: -87.6298, recordedAt: "2026-08-28T12:00:00.000Z", status: "on duty" }, locale: "es" }));
    expect(screen.getByText(/Ubicación actual autorizada/i)).toBeTruthy(); expect(screen.getByTestId("current-location-map").getAttribute("data-location")).toBe("41.8781,-87.6298"); expect(screen.queryByText(/historial|trayectoria/i)).toBeNull();
  });
  test("renders a no-location fallback when the server releases no current point", async () => {
    serverStubs.getRequestLocale.mockResolvedValue("es");
    serverStubs.createSupabaseServerClient.mockResolvedValue({});
    serverStubs.getAuthenticatedDispatchContext.mockResolvedValue({ companyId: "company-a", role: "dispatcher", userId: "manager-a" });
    serverStubs.getAuthorizedCurrentLocation.mockResolvedValue(null);

    render(await OperationsMapPage());

    expect(screen.getByRole("status").textContent).toMatch(/No hay una ubicación actual autorizada/i);
    expect(screen.queryByTestId("current-location-map")).toBeNull();
    expect(screen.queryByText(/41\.8781|-87\.6298|historial|trayectoria/i)).toBeNull();
  });
  test("localizes map operational status rather than exposing its wire enum", () => {
    const location = {
      accuracyMeters: 8,
      driverLabel: "Avery",
      freshness: "current" as const,
      latitude: 41.8781,
      loadNumber: "CF-100",
      longitude: -87.6298,
      operationalStatus: "en_route_to_delivery",
      recordedAt: "2026-08-28T12:00:00.000Z",
    };
    const { rerender } = render(createElement(OperationsMapContent, { currentLocation: location, locale: "en" }));
    expect(screen.getByText(/Avery · En route to delivery/)).toBeTruthy();
    expect(screen.queryByText(/en_route_to_delivery/)).toBeNull();

    rerender(createElement(OperationsMapContent, { currentLocation: location, locale: "es" }));
    expect(screen.getByText(/Avery · En camino a entrega/)).toBeTruthy();
    expect(screen.queryByText(/en_route_to_delivery/)).toBeNull();
  });
  test("labels an on-duty driver without a load context in English and Spanish", () => {
    const onDutyLocation = {
      accuracyMeters: 8,
      driverLabel: "Avery",
      freshness: "current" as const,
      latitude: 41.8781,
      loadNumber: null,
      longitude: -87.6298,
      operationalStatus: null,
      recordedAt: "2026-08-28T12:00:00.000Z",
    };
    const { rerender } = render(createElement(OperationsMapContent, { currentLocation: onDutyLocation, locale: "en" }));
    expect(screen.getByText(/Avery · On duty/)).toBeTruthy();
    expect(screen.queryByText("—")).toBeNull();

    rerender(createElement(OperationsMapContent, { currentLocation: onDutyLocation, locale: "es" }));
    expect(screen.getByText(/Avery · De servicio/)).toBeTruthy();
    expect(screen.queryByText("—")).toBeNull();
  });
  test("loads one server-authorized current location and load context without a history request", async () => {
    serverStubs.getRequestLocale.mockResolvedValue("en");
    serverStubs.createSupabaseServerClient.mockResolvedValue({});
    serverStubs.getAuthenticatedDispatchContext.mockResolvedValue({ companyId: "company-a", role: "dispatcher", userId: "manager-a" });
    serverStubs.getAuthorizedCurrentLocation.mockResolvedValue({
      accuracyMeters: 8,
      driverLabel: "Avery",
      freshness: "current",
      latitude: 41.8781,
      loadNumber: "CF-100",
      longitude: -87.6298,
      operationalStatus: "en_route_to_delivery",
      recordedAt: "2026-08-28T12:00:00.000Z",
    });

    render(await OperationsMapPage());

    expect(screen.getByTestId("current-location-map").getAttribute("data-location")).toBe("41.8781,-87.6298");
    expect(screen.getByText("CF-100")).toBeTruthy();
    expect(serverStubs.getAuthorizedCurrentLocation).toHaveBeenCalledWith({ client: {}, companyId: "company-a" });
    expect(screen.queryByText(/history|track points/i)).toBeNull();
  });
});
