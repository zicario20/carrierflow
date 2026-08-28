import { describe, expect, test } from "vitest";

import { createCompanyInvitation } from "./write-audit";

describe("createCompanyInvitation", () => {
  test("returns forbidden without invoking the database for a driver", async () => {
    let rpcWasCalled = false;

    const result = await createCompanyInvitation({
      client: {
        async rpc() {
          rpcWasCalled = true;
          return { data: null, error: null };
        },
      },
      actorRole: "driver",
      companyId: "11111111-1111-1111-1111-111111111111",
      email: "driver@carrierflow.test",
      role: "driver",
    });

    expect(result).toEqual({
      ok: false,
      error: {
        code: "forbidden",
        message: "You do not have permission to perform this action.",
      },
    });
    expect(rpcWasCalled).toBe(false);
  });

  test("uses the database-authorized RPC for an owner and returns the created invitation", async () => {
    const calls: Array<Readonly<{ name: string; arguments: unknown }>> = [];

    const result = await createCompanyInvitation({
      client: {
        async rpc(name, arguments_) {
          calls.push({ name, arguments: arguments_ });
          return {
            data: {
              id: "33333333-3333-3333-3333-333333333333",
              company_id: "11111111-1111-1111-1111-111111111111",
              invited_email: "driver@carrierflow.test",
              role: "driver",
              status: "pending",
            },
            error: null,
          };
        },
      },
      actorRole: "owner",
      companyId: "11111111-1111-1111-1111-111111111111",
      email: "driver@carrierflow.test",
      role: "driver",
    });

    expect(calls).toEqual([
      {
        name: "create_company_invitation",
        arguments: {
          target_company_id: "11111111-1111-1111-1111-111111111111",
          invitee_email: "driver@carrierflow.test",
          invitee_role: "driver",
        },
      },
    ]);
    expect(result).toEqual({
      ok: true,
      data: {
        id: "33333333-3333-3333-3333-333333333333",
        companyId: "11111111-1111-1111-1111-111111111111",
        email: "driver@carrierflow.test",
        role: "driver",
        status: "pending",
      },
    });
  });
});
