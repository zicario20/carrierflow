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
