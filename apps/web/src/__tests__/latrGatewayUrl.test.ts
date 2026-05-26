import { describe, expect, it } from "bun:test";
import { latrGatewayBaseUrl } from "@/lib/latrGatewayUrl";

describe("latrGatewayBaseUrl", () => {
  it("defaults to local gateway in local env", () => {
    const prev = process.env.NEXT_PUBLIC_LATR_GATEWAY_URL;
    const prevEnv = process.env.NEXT_PUBLIC_APP_ENV;
    delete process.env.NEXT_PUBLIC_LATR_GATEWAY_URL;
    process.env.NEXT_PUBLIC_APP_ENV = "local";
    expect(latrGatewayBaseUrl()).toBe("http://127.0.0.1:8080");
    if (prev !== undefined) process.env.NEXT_PUBLIC_LATR_GATEWAY_URL = prev;
    else delete process.env.NEXT_PUBLIC_LATR_GATEWAY_URL;
    if (prevEnv !== undefined) process.env.NEXT_PUBLIC_APP_ENV = prevEnv;
    else delete process.env.NEXT_PUBLIC_APP_ENV;
  });
});
