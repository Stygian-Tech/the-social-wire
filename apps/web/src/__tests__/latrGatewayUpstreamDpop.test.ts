import { describe, expect, it } from "bun:test";
import {
  pdsXrpcMethodForGatewayRequest,
  pdsXrpcMethodForSocialWireGatewayRequest,
} from "@/lib/latrGatewayUpstreamDpop";

describe("pdsXrpcMethodForGatewayRequest", () => {
  it("maps POST /v1/latr/saves to createRecord", () => {
    expect(pdsXrpcMethodForGatewayRequest("POST", "/v1/latr/saves")).toEqual({
      xrpcMethod: "com.atproto.repo.createRecord",
      httpMethod: "POST",
    });
  });

  it("maps PATCH state routes to putRecord", () => {
    expect(
      pdsXrpcMethodForGatewayRequest(
        "PATCH",
        "/v1/latr/saves/ABC123/state"
      )
    ).toEqual({
      xrpcMethod: "com.atproto.repo.putRecord",
      httpMethod: "POST",
    });
  });

  it("maps DELETE item routes to deleteRecord", () => {
    expect(
      pdsXrpcMethodForGatewayRequest("DELETE", "/v1/latr/saves/ABC123")
    ).toEqual({
      xrpcMethod: "com.atproto.repo.deleteRecord",
      httpMethod: "POST",
    });
  });

  it("maps GET /v1/latr/saves to listRecords", () => {
    expect(pdsXrpcMethodForGatewayRequest("GET", "/v1/latr/saves")).toEqual({
      xrpcMethod: "com.atproto.repo.listRecords",
      httpMethod: "GET",
    });
  });
});

describe("pdsXrpcMethodForSocialWireGatewayRequest", () => {
  it("maps bootstrap stream to listRecords for PDS-backed sidebar discovery", () => {
    expect(
      pdsXrpcMethodForSocialWireGatewayRequest(
        "GET",
        "/v1/appview/bootstrap-stream"
      )
    ).toEqual({
      xrpcMethod: "com.atproto.repo.listRecords",
      httpMethod: "GET",
    });
  });

  it("maps publication sidebar reads to listRecords", () => {
    expect(
      pdsXrpcMethodForSocialWireGatewayRequest(
        "GET",
        "/v1/publications/sidebar?phase=priority"
      )
    ).toEqual({
      xrpcMethod: "com.atproto.repo.listRecords",
      httpMethod: "GET",
    });
  });

  it("maps publication refresh to listRecords", () => {
    expect(
      pdsXrpcMethodForSocialWireGatewayRequest(
        "POST",
        "/v1/publications/refresh"
      )
    ).toEqual({
      xrpcMethod: "com.atproto.repo.listRecords",
      httpMethod: "GET",
    });
  });

  it("does not require upstream DPoP for mark-all-read", () => {
    expect(
      pdsXrpcMethodForSocialWireGatewayRequest(
        "POST",
        "/v1/appview/mark-all-read"
      )
    ).toBeNull();
  });
});
