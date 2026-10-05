import { afterAll, beforeAll, describe, expect, it, mock, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { FinanceCustomize } from "@/components/FinanceCustomize";
import * as Finance from "@/lib/financeFeedClient";
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

const globalKeys = ["DOMRect", "Element", "HTMLElement", "Node", "getComputedStyle", "requestAnimationFrame", "cancelAnimationFrame"] as const;
const originals = new Map(globalKeys.map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
beforeAll(() => {
 const values = { DOMRect: window.DOMRect, Element: window.Element, HTMLElement: window.HTMLElement, Node: window.Node, getComputedStyle: window.getComputedStyle.bind(window), requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: (handle: ReturnType<typeof setTimeout>) => clearTimeout(handle) };
 for (const key of globalKeys) Object.defineProperty(globalThis, key, { configurable: true, writable: true, value: values[key] });
});
afterAll(() => {
 for (const key of globalKeys) {
  const original = originals.get(key);
  if (original) Object.defineProperty(globalThis, key, original);
  else Reflect.deleteProperty(globalThis, key);
 }
});
it("keeps long saved interests readable and removable inside the responsive dialog", async () => {
 const instrument = { id: "fin_long", name: "Issuer".repeat(50), symbol: "LONG", kind: "equity", exchange: "NASDAQ", exchangeName: "Nasdaq Global Select Market" };
 const selection: Finance.FinanceSelection = { kind: "instrument", reference: instrument.id, createdAt: "2026-10-05T00:00:00Z", updatedAt: "2026-10-05T00:00:00Z" };
 const sectors = spyOn(Finance, "getFinanceSectors").mockResolvedValue({ sectors: [{ id: "technology", name: "Technology" }] });
 const search = spyOn(Finance, "searchFinanceInstruments").mockResolvedValue({ instruments: [instrument] });
 const save = mock(async () => undefined);
 const client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 } } });
 try {
  render(<QueryClientProvider client={client}><FinanceCustomize open onOpenChange={() => {}} selections={[selection]} save={save} saving={false} signedIn /></QueryClientProvider>);
  const label = `${financeInterestLabel(selection, [instrument], [])} · Remove`;
  const remove = await screen.findByRole("button", { name: label });
  const dialog = screen.getByRole("dialog", { name: "Customize Finance" });
  expect(dialog.classList.contains("grid-cols-[minmax(0,1fr)]")).toBe(true);
  expect(dialog.classList.contains("sm:max-w-2xl")).toBe(true);
  expect(remove.classList.contains("max-w-full")).toBe(true);
  expect(remove.classList.contains("whitespace-normal")).toBe(true);
  expect(remove.classList.contains("[overflow-wrap:anywhere]")).toBe(true);
  expect(remove.classList.contains("h-auto")).toBe(true);
  expect(remove.textContent).toBe(label);
  expect(remove.hasAttribute("disabled")).toBe(true);
  fireEvent.click(screen.getByRole("checkbox"));
  fireEvent.click(remove);
  await waitFor(() => expect(save).toHaveBeenCalledWith({ selection, remove: true }));
 } finally {
  cleanup(); client.clear(); sectors.mockRestore(); search.mockRestore();
 }
});
