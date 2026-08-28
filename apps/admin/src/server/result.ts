export type OkResult<T> = Readonly<{
  ok: true;
  data: T;
}>;

export type ForbiddenResult = Readonly<{
  ok: false;
  error: Readonly<{
    code: "forbidden";
    message: "You do not have permission to perform this action.";
  }>;
}>;

export type ValidationErrorResult = Readonly<{
  ok: false;
  error: Readonly<{
    code: "validation";
    message: string;
    field?: string;
  }>;
}>;

export type MutationResult<T> = OkResult<T> | ForbiddenResult | ValidationErrorResult;

export function ok<T>(data: T): OkResult<T> {
  return { ok: true, data };
}

export function forbidden(): ForbiddenResult {
  return {
    ok: false,
    error: {
      code: "forbidden",
      message: "You do not have permission to perform this action.",
    },
  };
}

export function validationError(
  message: string,
  field?: string,
): ValidationErrorResult {
  return {
    ok: false,
    error: {
      code: "validation",
      message,
      ...(field ? { field } : {}),
    },
  };
}
