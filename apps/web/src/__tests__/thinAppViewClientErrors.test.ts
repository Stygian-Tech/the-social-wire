import { describe, expect, it } from "bun:test";
import {
  AppViewRequestError,
  shouldRetryAppViewRequest,
} from "@/lib/thinAppViewClient";

describe("AppView client retry policy", () => {
  it("retries one retryable response and exposes request diagnostics", () => {
    const error = new AppViewRequestError({
      message: "temporarily unavailable",
      status: 503,
      requestId: "req-123",
      retryable: true,
    });
    expect(error.requestId).toBe("req-123");
    expect(shouldRetryAppViewRequest(0, error)).toBe(true);
    expect(shouldRetryAppViewRequest(1, error)).toBe(false);
  });

  it("never retries malformed requests or ordinary errors", () => {
    expect(
      shouldRetryAppViewRequest(
        0,
        new AppViewRequestError({
          message: "invalid cursor",
          status: 400,
          retryable: false,
        })
      )
    ).toBe(false);
    expect(shouldRetryAppViewRequest(0, new Error("decode failed"))).toBe(false);
  });
});
