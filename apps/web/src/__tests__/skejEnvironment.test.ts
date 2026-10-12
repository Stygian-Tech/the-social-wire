import { expect, test } from "bun:test";
import { AT_PROTO_OAUTH_SCOPES } from "@/lib/atprotoOAuthScopes";
import { BRAND_ACCOUNT_OAUTH_SCOPES } from "@/lib/brandAccounts/brandAccountScopes";
import { getSkejEnvironment, SKEJ_SCHEDULING_METHODS, SKEJ_SCHEDULING_SCOPES, skejScopesForEnvironment } from "@/lib/skej/skejEnvironment";

function withEnvironment(environment: string, origin: string | undefined, check: () => void) {
  const prior = [process.env.NEXT_PUBLIC_APP_ENV, process.env.NEXT_PUBLIC_LOCAL_SKEJ_API_URL];
  process.env.NEXT_PUBLIC_APP_ENV = environment;
  if (origin === undefined) delete process.env.NEXT_PUBLIC_LOCAL_SKEJ_API_URL; else process.env.NEXT_PUBLIC_LOCAL_SKEJ_API_URL = origin;
  try { check(); } finally {
    for (const [index, key] of ["NEXT_PUBLIC_APP_ENV", "NEXT_PUBLIC_LOCAL_SKEJ_API_URL"].entries()) {
      if (prior[index] === undefined) delete process.env[key]; else process.env[key] = prior[index];
    }
  }
}
test("Skej local ports use the DID-web audience and hosted environments ignore overrides", () => {
  withEnvironment("local", "https://appview.atmosbox.test:8444", () => {
    expect(getSkejEnvironment().audience).toBe("did:web:appview.atmosbox.test%3A8444#skej_scheduler");
    expect(skejScopesForEnvironment(SKEJ_SCHEDULING_SCOPES.join(" "))).toContain("aud=did:web:appview.atmosbox.test%3A8444%23skej_scheduler");
  });
  withEnvironment("production", "http://unsafe.test", () => expect(getSkejEnvironment().api).toBe("https://api.skej.at"));
  withEnvironment("dev", "http://unsafe.test", () => expect(getSkejEnvironment().api).toBe("https://api.testing.skej.at"));
});
test("local scheduling accepts only a bare HTTPS origin", () => {
  for (const origin of ["http://localhost:8084", "https://user:secret@example.test", "https://example.test/path", "https://example.test/?secret=1", "https://example.test/#fragment"]) withEnvironment("local", origin, () => expect(getSkejEnvironment).toThrow("HTTPS Skej Origin"));
});
test("personal and brand consent grant only the five Skej service methods with no scheduler repo writes", () => {
  expect(SKEJ_SCHEDULING_METHODS).toHaveLength(5);
  for (const scopes of [AT_PROTO_OAUTH_SCOPES, BRAND_ACCOUNT_OAUTH_SCOPES]) {
    expect(scopes.split(" ").filter(scope => scope.includes("skej"))).toEqual(SKEJ_SCHEDULING_SCOPES);
    expect(scopes).not.toContain("rpc:com.atproto.server.getServiceAuth");
    expect(scopes).not.toContain("repo:at.skej");
  }
});
