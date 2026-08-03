import { describe, expect, it } from "bun:test";

import { CursorSingleFlight } from "@/lib/cursorSingleFlight";

describe("CursorSingleFlight", () => {
  it("shares one active request for simultaneous triggers in a feed", async () => {
    const controller = new CursorSingleFlight();
    let calls = 0;
    let resolveRequest: (() => void) | undefined;
    const request = () => {
      calls += 1;
      return new Promise<void>((resolve) => {
        resolveRequest = resolve;
      });
    };

    const first = controller.run({
      feedKey: "subscribed:all",
      cursor: "cursor-1",
      request,
    });
    const second = controller.run({
      feedKey: "subscribed:all",
      cursor: "cursor-1",
      request,
    });

    expect(first).toBe(second);
    await Promise.resolve();
    expect(calls).toBe(1);
    resolveRequest?.();
    await first;
  });

  it("unlocks after failure and reset permits a new feed request", async () => {
    const controller = new CursorSingleFlight();
    let calls = 0;
    const failing = () => {
      calls += 1;
      return Promise.reject(new Error("failed"));
    };

    await expect(
      controller.run({
        feedKey: "subscribed:all",
        cursor: "cursor-1",
        request: failing,
      }),
    ).rejects.toThrow("failed");
    await expect(
      controller.run({
        feedKey: "subscribed:all",
        cursor: "cursor-1",
        request: failing,
      }),
    ).rejects.toThrow("failed");
    expect(calls).toBe(2);

    controller.reset();
    await controller.run({
      feedKey: "following:all",
      cursor: "cursor-2",
      request: () => Promise.resolve(),
    });
  });

  it("does not reuse an obsolete request after the cursor advances", async () => {
    const controller = new CursorSingleFlight();
    let calls = 0;
    const pending = new Promise<void>(() => {});

    void controller.run({
      feedKey: "subscribed:all",
      cursor: "cursor-1",
      request: () => {
        calls += 1;
        return pending;
      },
    });
    await controller.run({
      feedKey: "subscribed:all",
      cursor: "cursor-2",
      request: () => {
        calls += 1;
        return Promise.resolve();
      },
    });

    expect(calls).toBe(2);
  });
});
