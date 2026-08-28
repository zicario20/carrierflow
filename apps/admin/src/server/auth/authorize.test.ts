import { describe, expect, test } from "vitest";

import { authorize } from "./authorize";

describe("authorize", () => {
  test("allows an owner to create a company invitation", () => {
    const result = authorize({
      role: "owner",
      permission: "company.invitation.create",
    });

    expect(result).toEqual({
      ok: true,
      data: { permission: "company.invitation.create" },
    });
  });

  test("returns a typed forbidden result for a driver administrative attempt", () => {
    const result = authorize({
      role: "driver",
      permission: "company.invitation.create",
    });

    expect(result).toEqual({
      ok: false,
      error: {
        code: "forbidden",
        message: "You do not have permission to perform this action.",
      },
    });
  });
});
