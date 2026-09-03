import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const root = new URL("../", import.meta.url);
const read = (path) => readFileSync(new URL(path, root), "utf8");

function functionBody(source, signature) {
  const start = source.indexOf(signature);
  assert.notEqual(start, -1, `missing function: ${signature}`);
  const open = source.indexOf("{", start + signature.length);
  assert.notEqual(open, -1, `missing function body: ${signature}`);
  let depth = 0;
  for (let index = open; index < source.length; index += 1) {
    if (source[index] === "{") depth += 1;
    if (source[index] === "}") depth -= 1;
    if (depth === 0) return source.slice(open + 1, index);
  }
  assert.fail(`unterminated function body: ${signature}`);
}

test("locked Native SDK credential mutations have definite returned outcomes", () => {
  const packageJson = JSON.parse(read("package.json"));
  const packageLock = JSON.parse(read("package-lock.json"));
  const locked = packageLock.packages["node_modules/@native-sdk/cli"];

  assert.equal(packageJson.devDependencies["@native-sdk/cli"], "0.10.1");
  assert.deepEqual(
    {
      version: locked.version,
      resolved: locked.resolved,
      integrity: locked.integrity,
    },
    {
      version: "0.10.1",
      resolved: "https://registry.npmjs.org/@native-sdk/cli/-/cli-0.10.1.tgz",
      integrity:
        "sha512-1s1Fvn217UzHUjzK0YBziHTLX8D6yDGyIIQhr7r0WGX0Cxxjl06rH6LIdSrg3dDrRGBNaUIjE/QrzAot1dkwyg==",
    },
  );

  const windowsHost = read(
    "node_modules/@native-sdk/cli/src/platform/windows/webview2_host.cpp",
  );
  const windowsSet = functionBody(
    windowsHost,
    "int native_sdk_windows_set_credential(",
  );
  const windowsDelete = functionBody(
    windowsHost,
    "int native_sdk_windows_delete_credential(",
  );
  assert.match(
    windowsSet,
    /BOOL ok = cred_write\(&credential, 0\);[\s\S]*DWORD error = ok \? ERROR_SUCCESS : GetLastError\(\);[\s\S]*FreeLibrary\(advapi\);\s*if \(ok\) return 1;\s*return error == ERROR_ACCESS_DENIED \? -3 : -1;/,
  );
  assert.match(
    windowsDelete,
    /BOOL ok = cred_delete\(target\.c_str\(\), CRED_TYPE_GENERIC, 0\);[\s\S]*DWORD error = ok \? ERROR_SUCCESS : GetLastError\(\);[\s\S]*FreeLibrary\(advapi\);\s*if \(ok\) return 1;\s*if \(error == ERROR_NOT_FOUND\) return 0;\s*return error == ERROR_ACCESS_DENIED \? -3 : -1;/,
  );

  const windowsRoot = read(
    "node_modules/@native-sdk/cli/src/platform/windows/root.zig",
  );
  const windowsSetWrapper = functionBody(
    windowsRoot,
    "fn setCredential(context: ?*anyopaque, credential: platform_mod.Credential)",
  );
  const windowsDeleteWrapper = functionBody(
    windowsRoot,
    "fn deleteCredential(context: ?*anyopaque, key: platform_mod.CredentialKey)",
  );
  assert.match(
    windowsSetWrapper,
    /if \(result <= 0\) return error\.CredentialStoreFailed;\s*$/,
  );
  assert.match(
    windowsDeleteWrapper,
    /if \(result == 0\) return error\.CredentialNotFound;\s*$/,
  );

  const macosHost = read(
    "node_modules/@native-sdk/cli/src/platform/macos/cef_host.mm",
  );
  const macosStatus = functionBody(
    macosHost,
    "static int NativeSdkCredentialStatus(",
  );
  const macosSet = functionBody(
    macosHost,
    "int native_sdk_appkit_set_credential(",
  );
  const macosDelete = functionBody(
    macosHost,
    "int native_sdk_appkit_delete_credential(",
  );
  assert.match(macosStatus, /if \(status == errSecSuccess\) return 1;/);
  assert.match(
    macosSet,
    /OSStatus status = SecItemUpdate\([\s\S]*if \(status == errSecItemNotFound\) \{[\s\S]*status = SecItemAdd\([\s\S]*return NativeSdkCredentialStatus\(status, -1\);/,
  );
  assert.match(
    macosDelete,
    /OSStatus status = SecItemDelete\([\s\S]*return NativeSdkCredentialStatus\(status, 0\);/,
  );

  const macosRoot = read(
    "node_modules/@native-sdk/cli/src/platform/macos/root.zig",
  );
  const macosSetWrapper = functionBody(
    macosRoot,
    "fn setCredential(context: ?*anyopaque, credential: platform_mod.Credential)",
  );
  const macosDeleteWrapper = functionBody(
    macosRoot,
    "fn deleteCredential(context: ?*anyopaque, key: platform_mod.CredentialKey)",
  );
  assert.match(
    macosSetWrapper,
    /if \(result <= 0\) return error\.CredentialStoreFailed;\s*$/,
  );
  assert.match(
    macosDeleteWrapper,
    /if \(result == 0\) return error\.CredentialNotFound;\s*$/,
  );

  const platformTypes = read(
    "node_modules/@native-sdk/cli/src/platform/types.zig",
  );
  const publicSet = functionBody(
    platformTypes,
    "pub fn setCredential(self: PlatformServices, credential: Credential)",
  );
  const publicDelete = functionBody(
    platformTypes,
    "pub fn deleteCredential(self: PlatformServices, key: CredentialKey)",
  );
  assert.match(publicSet, /return set_fn\(self\.context, credential\);\s*$/);
  assert.match(publicDelete, /return delete_fn\(self\.context, key\);\s*$/);
});
