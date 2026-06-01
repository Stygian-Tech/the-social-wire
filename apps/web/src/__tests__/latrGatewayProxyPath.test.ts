import { describe, expect, it } from "bun:test";

import { latrGatewayProxyPath } from "@/lib/latrGatewayProxyPath";

describe("latrGatewayProxyPath", () => {
  it("maps gateway paths to the same-origin proxy route", () => {
    expect(latrGatewayProxyPath("/v1/latr/saves")).toBe("/api/latr-gateway/v1/latr/saves");
    expect(latrGatewayProxyPath("v1/latr/og-preview?url=https://example.com")).toBe(
      "/api/latr-gateway/v1/latr/og-preview?url=https://example.com"
    );
  });
});
