import { expect, it, spyOn } from "bun:test";
import { getFinanceCatalog } from "@/lib/financeFeedClient";
import { getSportsCatalog } from "@/lib/sportsFeedClient";

it("uses explicit local catalog fixtures without touching the live Gateway", async () => {
  const previous = process.env.NEXT_PUBLIC_USE_DUMMY_DATA;
  const fetch = spyOn(globalThis, "fetch").mockImplementation((() => { throw new Error("Fixtures must not access the network"); }) as unknown as typeof globalThis.fetch);
  process.env.NEXT_PUBLIC_USE_DUMMY_DATA = "true";
  try {
    expect((await getFinanceCatalog()).enabled).toBe(false);
    expect((await getSportsCatalog()).enabled).toBe(false);
    expect(fetch).not.toHaveBeenCalled();
  } finally {
    fetch.mockRestore();
    if (previous === undefined) delete process.env.NEXT_PUBLIC_USE_DUMMY_DATA;
    else process.env.NEXT_PUBLIC_USE_DUMMY_DATA = previous;
  }
});
