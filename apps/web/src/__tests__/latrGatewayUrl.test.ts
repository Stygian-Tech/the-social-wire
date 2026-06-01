import { describe, expect, it } from "bun:test";
import {
  DEFAULT_DEV_LATR_GATEWAY_URL,
  DEFAULT_PROD_LATR_GATEWAY_URL,
  DEFAULT_TEST_LATR_GATEWAY_URL,
  latrGatewayBaseUrl,
  latrGatewayBaseUrlForHostname,
  LOCAL_LATR_GATEWAY_URL,
} from "@/lib/latrGatewayUrl";

describe("latrGatewayBaseUrl", () => {
  function withEnv(
    vars: Record<string, string | undefined>,
    fn: () => void
  ): void {
    const prev: Record<string, string | undefined> = {};
    for (const key of Object.keys(vars)) {
      prev[key] = process.env[key];
      const value = vars[key];
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    try {
      fn();
    } finally {
      for (const [key, value] of Object.entries(prev)) {
        if (value === undefined) delete process.env[key];
        else process.env[key] = value;
      }
    }
  }

  it("defaults to local gateway in local env", () => {
    withEnv(
      {
        NEXT_PUBLIC_LATR_GATEWAY_URL: undefined,
        NEXT_PUBLIC_APP_ENV: "local",
      },
      () => {
        expect(latrGatewayBaseUrl()).toBe(LOCAL_LATR_GATEWAY_URL);
      }
    );
  });

  it("defaults to api.testing.latr.link for test env", () => {
    withEnv(
      {
        NEXT_PUBLIC_LATR_GATEWAY_URL: undefined,
        NEXT_PUBLIC_APP_ENV: "test",
      },
      () => {
        expect(latrGatewayBaseUrl()).toBe(DEFAULT_TEST_LATR_GATEWAY_URL);
      }
    );
  });

  it("defaults to api.testing.latr.link for dev env", () => {
    withEnv(
      {
        NEXT_PUBLIC_LATR_GATEWAY_URL: undefined,
        NEXT_PUBLIC_APP_ENV: "dev",
      },
      () => {
        expect(latrGatewayBaseUrl()).toBe(DEFAULT_DEV_LATR_GATEWAY_URL);
      }
    );
  });

  it("defaults to api.latr.link for prod env", () => {
    withEnv(
      {
        NEXT_PUBLIC_LATR_GATEWAY_URL: undefined,
        NEXT_PUBLIC_APP_ENV: "prod",
      },
      () => {
        expect(latrGatewayBaseUrl()).toBe(DEFAULT_PROD_LATR_GATEWAY_URL);
      }
    );
  });

  it("prefers explicit NEXT_PUBLIC_LATR_GATEWAY_URL", () => {
    withEnv(
      {
        NEXT_PUBLIC_LATR_GATEWAY_URL: "https://custom.example/",
        NEXT_PUBLIC_APP_ENV: "prod",
      },
      () => {
        expect(latrGatewayBaseUrl()).toBe("https://custom.example");
      }
    );
  });

  it("maps testing.thesocialwire.app to api.testing.latr.link", () => {
    expect(latrGatewayBaseUrlForHostname("testing.thesocialwire.app")).toBe(
      DEFAULT_TEST_LATR_GATEWAY_URL
    );
  });
});
