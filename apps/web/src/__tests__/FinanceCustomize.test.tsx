import { describe, expect, it } from "bun:test";
import { financeInterestLabel } from "@/lib/financeInterestLabel";
describe("Finance interest labels", () => {
 it("resolves saved public references into readable disambiguated labels", () => {
  const instruments = [{id:"fin_fixture",name:"Apple Inc.",symbol:"AAPL",kind:"equity",exchange:"NASDAQ"}];
  expect(financeInterestLabel({kind:"instrument",reference:"fin_fixture"},instruments,[])).toBe("Apple Inc. · AAPL · Exchange: NASDAQ · equity");
  expect(financeInterestLabel({kind:"sector",reference:"technology"},[],[{id:"technology",name:"Technology"}])).toBe("Technology");
 });
 it("uses unavailable labels for missing references without exposing opaque identifiers", () => {
  expect(financeInterestLabel({kind:"instrument",reference:"fin_missing"},[],[])).toBe("Unavailable Instrument");
  expect(financeInterestLabel({kind:"sector",reference:"missing"},[],[])).toBe("Unavailable Sector");
 });
});
