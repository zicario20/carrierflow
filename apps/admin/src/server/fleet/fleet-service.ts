import "server-only";

import { authorize, type CompanyRole } from "../auth/authorize";
import {
  forbidden,
  ok,
  validationError,
  type MutationResult,
} from "../result";

type FleetMutationName =
  | "create_driver"
  | "update_driver"
  | "create_vehicle"
  | "update_vehicle"
  | "assign_driver_vehicle"
  | "start_driver_shift"
  | "end_driver_shift";

type RpcError = Readonly<{
  code?: string;
}>;

type FleetReadResponse = Readonly<{
  data: unknown | null;
  error: RpcError | null;
}>;

type FleetReadQuery = Readonly<{
  eq: (column: string, value: string) => FleetReadQuery;
  maybeSingle: () => PromiseLike<FleetReadResponse>;
  order: (column: string) => PromiseLike<FleetReadResponse>;
}>;

/**
 * This is deliberately an RLS-bound request client. It does not expose direct
 * table writes or a service-role credential; the fleet RPCs remain the final
 * authorization and audit boundary.
 */
export type TrustedFleetSupabaseClient = Readonly<{
  rpc: (
    functionName: FleetMutationName,
    arguments_: Readonly<Record<string, unknown>>,
  ) => Promise<Readonly<{ data: unknown | null; error: RpcError | null }>>;
}>;

/**
 * Read clients are authenticated request clients, so PostgreSQL RLS remains
 * authoritative. This intentionally exposes no service-role or table writes.
 */
export type TrustedFleetReadClient = Readonly<{
  from: (table: "drivers" | "vehicles") => Readonly<{
    select: (columns: string) => FleetReadQuery;
  }>;
}>;

/**
 * Records are deactivated instead of physically deleted so assignments,
 * shifts, and immutable audit history remain verifiable.
 */
export type FleetStatus = "active" | "inactive";

export type FleetDriver = Readonly<{
  id: string;
  companyId: string;
  membershipId: string;
  displayName: string;
  status: FleetStatus;
}>;

export type FleetVehicle = Readonly<{
  id: string;
  companyId: string;
  unitNumber: string;
  type: string;
  capacityLbs: number | null;
  status: FleetStatus;
}>;

export type DriverVehicleAssignment = Readonly<{
  id: string;
  companyId: string;
  driverId: string;
  vehicleId: string;
  assignedAt: string;
  unassignedAt: string | null;
}>;

export type DriverShift = Readonly<{
  id: string;
  companyId: string;
  driverId: string;
  onDutyAt: string;
  offDutyAt: string | null;
}>;

type ManagerInput = Readonly<{
  actorRole: CompanyRole;
  client: TrustedFleetSupabaseClient;
  companyId: string;
}>;

export type CreateDriverInput = ManagerInput &
  Readonly<{
    membershipId: string;
    displayName: string;
  }>;

export type UpdateDriverInput = ManagerInput &
  Readonly<{
    driverId: string;
    displayName: string;
    status: FleetStatus;
  }>;

/** Deliberate non-destructive replacement for deleting a driver profile. */
export type DeactivateDriverInput = Omit<UpdateDriverInput, "status">;

export type CreateVehicleInput = ManagerInput &
  Readonly<{
    unitNumber: string;
    type: string;
    capacityLbs?: number | null;
  }>;

export type UpdateVehicleInput = ManagerInput &
  Readonly<{
    vehicleId: string;
    unitNumber: string;
    type: string;
    capacityLbs?: number | null;
    status: FleetStatus;
  }>;

/** Deliberate non-destructive replacement for deleting a vehicle record. */
export type DeactivateVehicleInput = Omit<UpdateVehicleInput, "status">;

export type AssignDriverVehicleInput = ManagerInput &
  Readonly<{
    driverId: string;
    vehicleId: string;
  }>;

export type OwnDriverShiftInput = Readonly<{
  actorRole: CompanyRole;
  client: TrustedFleetSupabaseClient;
  driverId: string;
}>;

export type ListFleetInput = Readonly<{
  client: TrustedFleetReadClient;
  companyId: string;
}>;

export type GetDriverInput = ListFleetInput &
  Readonly<{
    driverId: string;
  }>;

export type GetVehicleInput = ListFleetInput &
  Readonly<{
    vehicleId: string;
  }>;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isStatus(value: unknown): value is FleetStatus {
  return value === "active" || value === "inactive";
}

function parseDriver(value: unknown): FleetDriver | null {
  if (!isRecord(value) || !isStatus(value.status)) {
    return null;
  }
  const { company_id, display_name, id, membership_id, status } = value;
  if (
    typeof company_id !== "string" ||
    typeof display_name !== "string" ||
    typeof id !== "string" ||
    typeof membership_id !== "string"
  ) {
    return null;
  }
  return {
    id,
    companyId: company_id,
    membershipId: membership_id,
    displayName: display_name,
    status,
  };
}

function parseVehicle(value: unknown): FleetVehicle | null {
  if (!isRecord(value) || !isStatus(value.status)) {
    return null;
  }
  const { capacity_lbs, company_id, id, status, unit_number, vehicle_type } = value;
  if (
    typeof company_id !== "string" ||
    typeof id !== "string" ||
    typeof unit_number !== "string" ||
    typeof vehicle_type !== "string" ||
    (typeof capacity_lbs !== "number" && capacity_lbs !== null)
  ) {
    return null;
  }
  return {
    id,
    companyId: company_id,
    unitNumber: unit_number,
    type: vehicle_type,
    capacityLbs: capacity_lbs,
    status,
  };
}

function parseAssignment(value: unknown): DriverVehicleAssignment | null {
  if (!isRecord(value)) {
    return null;
  }
  const { assigned_at, company_id, driver_id, id, unassigned_at, vehicle_id } = value;
  if (
    typeof assigned_at !== "string" ||
    typeof company_id !== "string" ||
    typeof driver_id !== "string" ||
    typeof id !== "string" ||
    typeof vehicle_id !== "string" ||
    (typeof unassigned_at !== "string" && unassigned_at !== null)
  ) {
    return null;
  }
  return {
    id,
    companyId: company_id,
    driverId: driver_id,
    vehicleId: vehicle_id,
    assignedAt: assigned_at,
    unassignedAt: unassigned_at,
  };
}

function parseShift(value: unknown): DriverShift | null {
  if (!isRecord(value)) {
    return null;
  }
  const { company_id, driver_id, id, off_duty_at, on_duty_at } = value;
  if (
    typeof company_id !== "string" ||
    typeof driver_id !== "string" ||
    typeof id !== "string" ||
    typeof on_duty_at !== "string" ||
    (typeof off_duty_at !== "string" && off_duty_at !== null)
  ) {
    return null;
  }
  return {
    id,
    companyId: company_id,
    driverId: driver_id,
    onDutyAt: on_duty_at,
    offDutyAt: off_duty_at,
  };
}

function databaseFailure<T>(error: RpcError | null, message: string, field?: string): MutationResult<T> {
  if (error?.code === "42501") {
    return forbidden();
  }
  return validationError(message, field);
}

function parseRows<T>(value: unknown, parser: (row: unknown) => T | null): readonly T[] | null {
  if (!Array.isArray(value)) {
    return null;
  }
  const parsedRows = value.map(parser);
  return parsedRows.every((row): row is T => row !== null) ? parsedRows : null;
}

const driverColumns = "id,company_id,membership_id,display_name,status";
const vehicleColumns = "id,company_id,unit_number,vehicle_type,capacity_lbs,status";

/** Lists only records visible through the caller's authenticated PostgreSQL RLS policy. */
export async function listDrivers(input: ListFleetInput): Promise<MutationResult<readonly FleetDriver[]>> {
  const response = await input.client
    .from("drivers")
    .select(driverColumns)
    .eq("company_id", input.companyId)
    .order("display_name");
  if (response.error) {
    return databaseFailure(response.error, "Fleet drivers could not be loaded.");
  }
  const drivers = parseRows(response.data, parseDriver);
  return drivers ? ok(drivers) : validationError("Fleet drivers could not be loaded.");
}

/** Reads one driver only when both the requested tenant filter and RLS allow it. */
export async function getDriver(input: GetDriverInput): Promise<MutationResult<FleetDriver>> {
  const response = await input.client
    .from("drivers")
    .select(driverColumns)
    .eq("company_id", input.companyId)
    .eq("id", input.driverId)
    .maybeSingle();
  if (response.error) {
    return databaseFailure(response.error, "The fleet driver could not be loaded.");
  }
  if (response.data === null) {
    return forbidden();
  }
  const driver = parseDriver(response.data);
  return driver ? ok(driver) : validationError("The fleet driver could not be loaded.");
}

/** Lists only vehicles visible through the caller's authenticated PostgreSQL RLS policy. */
export async function listVehicles(input: ListFleetInput): Promise<MutationResult<readonly FleetVehicle[]>> {
  const response = await input.client
    .from("vehicles")
    .select(vehicleColumns)
    .eq("company_id", input.companyId)
    .order("unit_number");
  if (response.error) {
    return databaseFailure(response.error, "Fleet vehicles could not be loaded.");
  }
  const vehicles = parseRows(response.data, parseVehicle);
  return vehicles ? ok(vehicles) : validationError("Fleet vehicles could not be loaded.");
}

/** Reads one vehicle only when both the requested tenant filter and RLS allow it. */
export async function getVehicle(input: GetVehicleInput): Promise<MutationResult<FleetVehicle>> {
  const response = await input.client
    .from("vehicles")
    .select(vehicleColumns)
    .eq("company_id", input.companyId)
    .eq("id", input.vehicleId)
    .maybeSingle();
  if (response.error) {
    return databaseFailure(response.error, "The fleet vehicle could not be loaded.");
  }
  if (response.data === null) {
    return forbidden();
  }
  const vehicle = parseVehicle(response.data);
  return vehicle ? ok(vehicle) : validationError("The fleet vehicle could not be loaded.");
}

function authorizeManager<T>(role: CompanyRole, permission: "fleet.driver.manage" | "fleet.vehicle.manage" | "fleet.assignment.manage"): MutationResult<T> | null {
  const authorization = authorize({ permission, role });
  return authorization.ok ? null : authorization;
}

export async function createDriver(input: CreateDriverInput): Promise<MutationResult<FleetDriver>> {
  const authorization = authorizeManager<FleetDriver>(input.actorRole, "fleet.driver.manage");
  if (authorization) {
    return authorization;
  }

  const response = await input.client.rpc("create_driver", {
    driver_display_name: input.displayName,
    target_company_id: input.companyId,
    target_membership_id: input.membershipId,
  });
  if (response.error) {
    return databaseFailure(response.error, "The driver could not be created.", "displayName");
  }
  const driver = parseDriver(response.data);
  return driver ? ok(driver) : validationError("The driver could not be created.");
}

export async function updateDriver(input: UpdateDriverInput): Promise<MutationResult<FleetDriver>> {
  const authorization = authorizeManager<FleetDriver>(input.actorRole, "fleet.driver.manage");
  if (authorization) {
    return authorization;
  }

  const response = await input.client.rpc("update_driver", {
    driver_display_name: input.displayName,
    driver_status: input.status,
    target_company_id: input.companyId,
    target_driver_id: input.driverId,
  });
  if (response.error) {
    return databaseFailure(response.error, "The driver could not be updated.", "driver");
  }
  const driver = parseDriver(response.data);
  return driver ? ok(driver) : validationError("The driver could not be updated.");
}

export function deactivateDriver(input: DeactivateDriverInput): Promise<MutationResult<FleetDriver>> {
  return updateDriver({ ...input, status: "inactive" });
}

export async function createVehicle(input: CreateVehicleInput): Promise<MutationResult<FleetVehicle>> {
  const authorization = authorizeManager<FleetVehicle>(input.actorRole, "fleet.vehicle.manage");
  if (authorization) {
    return authorization;
  }

  const response = await input.client.rpc("create_vehicle", {
    target_company_id: input.companyId,
    vehicle_capacity_lbs: input.capacityLbs ?? null,
    vehicle_type_value: input.type,
    vehicle_unit_number: input.unitNumber,
  });
  if (response.error) {
    return databaseFailure(response.error, "The vehicle could not be created.", "unitNumber");
  }
  const vehicle = parseVehicle(response.data);
  return vehicle ? ok(vehicle) : validationError("The vehicle could not be created.");
}

export async function updateVehicle(input: UpdateVehicleInput): Promise<MutationResult<FleetVehicle>> {
  const authorization = authorizeManager<FleetVehicle>(input.actorRole, "fleet.vehicle.manage");
  if (authorization) {
    return authorization;
  }

  const response = await input.client.rpc("update_vehicle", {
    target_company_id: input.companyId,
    target_vehicle_id: input.vehicleId,
    vehicle_capacity_lbs: input.capacityLbs ?? null,
    vehicle_status: input.status,
    vehicle_type_value: input.type,
    vehicle_unit_number: input.unitNumber,
  });
  if (response.error) {
    return databaseFailure(response.error, "The vehicle could not be updated.", "vehicle");
  }
  const vehicle = parseVehicle(response.data);
  return vehicle ? ok(vehicle) : validationError("The vehicle could not be updated.");
}

export function deactivateVehicle(input: DeactivateVehicleInput): Promise<MutationResult<FleetVehicle>> {
  return updateVehicle({ ...input, status: "inactive" });
}

export async function assignDriverVehicle(
  input: AssignDriverVehicleInput,
): Promise<MutationResult<DriverVehicleAssignment>> {
  const authorization = authorizeManager<DriverVehicleAssignment>(input.actorRole, "fleet.assignment.manage");
  if (authorization) {
    return authorization;
  }

  const response = await input.client.rpc("assign_driver_vehicle", {
    target_company_id: input.companyId,
    target_driver_id: input.driverId,
    target_vehicle_id: input.vehicleId,
  });
  if (response.error) {
    return databaseFailure(
      response.error,
      "The driver and vehicle must be active before assignment.",
      "assignment",
    );
  }
  const assignment = parseAssignment(response.data);
  return assignment
    ? ok(assignment)
    : validationError("The driver and vehicle must be active before assignment.", "assignment");
}

async function mutateOwnShift(
  input: OwnDriverShiftInput,
  functionName: "start_driver_shift" | "end_driver_shift",
): Promise<MutationResult<DriverShift>> {
  if (input.actorRole !== "driver") {
    return forbidden();
  }

  const response = await input.client.rpc(functionName, { target_driver_id: input.driverId });
  if (response.error) {
    return databaseFailure(response.error, "The shift could not be updated.", "shift");
  }
  const shift = parseShift(response.data);
  return shift ? ok(shift) : validationError("The shift could not be updated.", "shift");
}

export function startOwnDriverShift(input: OwnDriverShiftInput): Promise<MutationResult<DriverShift>> {
  return mutateOwnShift(input, "start_driver_shift");
}

export function endOwnDriverShift(input: OwnDriverShiftInput): Promise<MutationResult<DriverShift>> {
  return mutateOwnShift(input, "end_driver_shift");
}
