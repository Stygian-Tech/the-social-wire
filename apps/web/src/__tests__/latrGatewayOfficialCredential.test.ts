import { describe, expect, it } from "bun:test";

import {
  normalizeLatrGatewayOfficialCredential,
  parseOfficialClientCredentialsMap,
  THE_SOCIAL_WIRE_WEB_CLIENT_ID,
} from "@/lib/latrGatewayOfficialCredential";

describe("normalizeLatrGatewayOfficialCredential", () => {
  it("passes through bare base64 credentials", () => {
    expect(normalizeLatrGatewayOfficialCredential("dGVzdA==")).toBe("dGVzdA==");
  });

  it("extracts credential from client-id=base64 pair", () => {
    expect(
      normalizeLatrGatewayOfficialCredential(
        `${THE_SOCIAL_WIRE_WEB_CLIENT_ID}=dGVzdC1zZWNyZXQ=`
      )
    ).toBe("dGVzdC1zZWNyZXQ=");
  });

  it("prefers the-social-wire-web in comma-separated maps", () => {
    const map = `${THE_SOCIAL_WIRE_WEB_CLIENT_ID}=dGVzdA==,latr-link-web=b3RoZXI=`;
    expect(normalizeLatrGatewayOfficialCredential(map)).toBe("dGVzdA==");
  });

  it("returns undefined for ambiguous multi-client maps", () => {
    expect(
      normalizeLatrGatewayOfficialCredential("alpha-web=one,beta-web=two")
    ).toBeUndefined();
  });
});

describe("parseOfficialClientCredentialsMap", () => {
  it("parses comma and semicolon separated entries", () => {
    expect(
      parseOfficialClientCredentialsMap(
        "the-social-wire-web=abc;latr-link-web=def"
      )
    ).toEqual({
      "the-social-wire-web": "abc",
      "latr-link-web": "def",
    });
  });
});
