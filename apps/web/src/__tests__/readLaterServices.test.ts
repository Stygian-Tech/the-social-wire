import { describe, expect, it } from "bun:test";
import {
  findReadLaterService,
  isLatrPdsReadLaterService,
  LATR_PDS_READ_LATER_SERVICE_IDS,
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
    expect(findReadLaterService("latrkit").label).toBe("LatrKit");
    expect(findReadLaterService("semble").label).toBe("Semble");
  });

  it("READ_LATER_SERVICES marks latr PDS providers as connected", () => {
    for (const id of LATR_PDS_READ_LATER_SERVICE_IDS) {
      const service = READ_LATER_SERVICES.find((s) => s.id === id);
      expect(service?.connected).toBe(true);
    }
  });

  it("isLatrPdsReadLaterService recognizes latr-link and latrkit", () => {
    expect(isLatrPdsReadLaterService("latr-link")).toBe(true);
    expect(isLatrPdsReadLaterService("latrkit")).toBe(true);
    expect(isLatrPdsReadLaterService("instapaper")).toBe(false);
    expect(isLatrPdsReadLaterService(null)).toBe(false);
  });
});
