type JsonObject = Record<string, unknown>;

export function fail(path: string, message: string): never {
  throw new Error(`Invalid Host contract at ${path}: ${message}`);
}

export function record(value: unknown, path: string): JsonObject {
  if (typeof value !== "object" || value === null || Array.isArray(value))
    fail(path, "expected object");
  return value as JsonObject;
}

export function exactKeys(
  result: JsonObject,
  path: string,
  keys: readonly string[],
) {
  const actual = Object.keys(result);
  const expected = new Set(keys);
  const missing = keys.filter((key) => !Object.hasOwn(result, key));
  const extra = actual.reduce(
    (count, key) => count + Number(!expected.has(key)),
    0,
  );
  if (missing.length || extra) {
    // Only expected schema names may enter diagnostics. Unknown keys can
    // themselves contain user content or credentials, so report their count.
    const names = missing.slice(0, 8).join(", ").slice(0, 256);
    fail(
      path,
      `expected keys mismatch; missing (${missing.length}): ${names || "none"}${missing.length > 8 ? ", …" : ""}; unexpected fields: ${extra}`,
    );
  }
}

export function object(value: unknown, path: string, keys: readonly string[]) {
  const result = record(value, path);
  exactKeys(result, path, keys);
  return result;
}

export function stringValue(value: unknown, path: string) {
  if (typeof value !== "string") fail(path, "expected string");
  return value;
}

export function booleanValue(value: unknown, path: string) {
  if (typeof value !== "boolean") fail(path, "expected boolean");
  return value;
}

export function arrayValue<T>(
  value: unknown,
  path: string,
  decode: (item: unknown, path: string) => T,
) {
  if (!Array.isArray(value)) fail(path, "expected array");
  return value.map((item, index) => decode(item, `${path}[${index}]`));
}

export function wireId(value: unknown, path: string) {
  const result = stringValue(value, path);
  if (!/^(0|[1-9][0-9]*)$/.test(result)) fail(path, "expected wire integer");
  return result;
}

export function positiveWireId(value: unknown, path: string) {
  const result = wireId(value, path);
  if (result === "0") fail(path, "expected positive wire integer");
  return result;
}

export function positiveU64WireId(value: unknown, path: string) {
  const result = positiveWireId(value, path);
  if (
    result.length > 20 ||
    (result.length === 20 && result > "18446744073709551615")
  )
    fail(path, "expected positive u64 wire integer");
  return result;
}

export function u64WireInteger(value: unknown, path: string) {
  const result = wireId(value, path);
  if (
    result.length > 20 ||
    (result.length === 20 && result > "18446744073709551615")
  )
    fail(path, "expected u64 wire integer");
  return result;
}

export function numberValue(value: unknown, path: string) {
  if (typeof value !== "number" || !Number.isSafeInteger(value))
    fail(path, "expected safe integer");
  return value;
}

export function positiveNumber(value: unknown, path: string) {
  const result = numberValue(value, path);
  if (result <= 0) fail(path, "expected positive safe integer");
  return result;
}

export function nonNegativeNumber(value: unknown, path: string) {
  const result = numberValue(value, path);
  if (result < 0) fail(path, "expected non-negative safe integer");
  return result;
}

export function enumValue<const T extends readonly string[]>(
  value: unknown,
  path: string,
  values: T,
): T[number] {
  const result = stringValue(value, path);
  if (!(values as readonly string[]).includes(result))
    fail(path, "unexpected value for enum");
  return result as T[number];
}
