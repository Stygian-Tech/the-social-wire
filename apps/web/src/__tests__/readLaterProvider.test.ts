import { describe, expect, it } from "bun:test";
import { createReadLaterProvider } from "@/lib/readLaterProvider";

describe("createReadLaterProvider", () => {
  it("defaults to latr-gateway provider id", () => {
    const prev = process.env.NEXT_PUBLIC_LATR_READ_LATER_PROVIDER;
    delete process.env.NEXT_PUBLIC_LATR_READ_LATER_PROVIDER;
    const provider = createReadLaterProvider(
      {
        getTokenInfo: async () => ({ sub: "did:plc:viewer", aud: "https://pds.example" }),
      } as never,
      {} as never,
      "did:plc:viewer"
    );
    expect(provider.id).toBe("latr-gateway");
    if (prev !== undefined) {
      process.env.NEXT_PUBLIC_LATR_READ_LATER_PROVIDER = prev;
    }
  });
});
