import { describe, expect, it } from "bun:test";
import { financeExchangeLabel } from "@/lib/financeExchangeLabel";
import { financeInterestLabel } from "@/lib/financeInterestLabel";

describe("Finance exchange labels", () => {
  it("uses reviewed names while retaining exchange codes", () => {
    expect(financeExchangeLabel({ exchange: "US", exchangeName: "United States Composite" })).toBe("United States Composite (US)");
    expect(financeExchangeLabel({ exchange: "LN", exchangeName: "London Stock Exchange" })).toBe("London Stock Exchange (LN)");
  });
  it("does not infer an exchange from an unknown code", () => {
    expect(financeExchangeLabel({ exchange: "XYZ" })).toBe("Exchange: XYZ");
    expect(financeExchangeLabel({ exchange: "XYZ", exchangeName: "  " })).toBe("Exchange: XYZ");
    expect(financeExchangeLabel({})).toBeUndefined();
  });
  it("avoids duplicate names and handles reviewed name-only metadata", () => {
    expect(financeExchangeLabel({ exchange: "Nasdaq", exchangeName: "Nasdaq" })).toBe("Nasdaq");
    expect(financeExchangeLabel({ exchangeName: "Tokyo Stock Exchange" })).toBe("Tokyo Stock Exchange");
  });
  it("disambiguates customization search and selected interests", () => {
    expect(financeInterestLabel({ kind: "instrument", reference: "abc" }, [{ id: "abc", name: "ABC", symbol: "ABC", kind: "equity", exchange: "LN", exchangeName: "London Stock Exchange" }], [])).toBe("ABC · ABC · London Stock Exchange (LN) · equity");
  });
});
