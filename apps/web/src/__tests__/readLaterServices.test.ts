import { describe, expect, it } from "bun:test";
import {
  findReadLaterService,
  READ_LATER_SERVICES,
  READ_LATER_SERVICE_STORAGE_KEY,
} from "@/lib/readLaterServices";

describe("readLaterServices", () => {
  it("READ_LATER_SERVICE_STORAGE_KEY is stable", () => {
    expect(READ_LATER_SERVICE_STORAGE_KEY).toBe(
      "social-wire.saved.read-later-service"
    );
  });

  it("findReadLaterService returns latr-link by default", () => {
    expect(findReadLaterService(undefined).id).toBe("latr-link");
    expect(findReadLaterService(null).id).toBe("latr-link");
    expect(findReadLaterService("unknown").id).toBe("latr-link");
  });

  it("findReadLaterService resolves known service ids", () => {
    expect(findReadLaterService("instapaper").label).toBe("Instapaper");
    expect(findReadLaterService("readwise-reader").label).toBe(
      "Readwise Reader"
    );
  });

  it("READ_LATER_SERVICES marks latr-link as connected", () => {
    const latr = READ_LATER_SERVICES.find((s) => s.id === "latr-link");
    expect(latr?.connected).toBe(true);
  });
});
