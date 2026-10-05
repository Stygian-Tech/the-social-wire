import { afterEach, beforeAll, describe, expect, it, mock } from "bun:test";
import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { FinanceFeedPicker } from "@/components/FinanceFeedPicker";
import type { FinanceFeedDefinition } from "@/lib/financeFeedClient";

const definitions: FinanceFeedDefinition[] = [
  {
    id: "finance",
    title: "Finance",
    kind: "all",
    instrumentIDs: [],
    sectorIDs: [],
    description: "Market reporting",
  },
  {
    id: "industry:pharma",
    title: "Pharma",
    kind: "industry",
    instrumentIDs: [],
    sectorIDs: [],
    description: "Pharma reporting",
  },
  {
    id: "industry:technology",
    title: "Technology",
    kind: "industry",
    instrumentIDs: [],
    sectorIDs: [],
    description: "Technology reporting",
  },
  {
    id: "group:mag7",
    title: "Mag7",
    kind: "group",
    instrumentIDs: [],
    sectorIDs: [],
    description: "Group reporting",
  },
  {
    id: "instrument:apple",
    title: "Apple · AAPL · Nasdaq Stock Market (NASDAQ)",
    kind: "instrument",
    instrumentIDs: ["apple"],
    sectorIDs: [],
    description: "Apple reporting",
  },
  {
    id: "instrument:msft",
    title: "Microsoft · MSFT · NASDAQ",
    kind: "instrument",
    instrumentIDs: ["msft"],
    sectorIDs: [],
    description: "Microsoft reporting",
  },
];
beforeAll(() => {
  for (const name of ["HTMLElement", "Element", "Node", "DOMRect"] as const)
    Object.defineProperty(globalThis, name, {
      configurable: true,
      value: window[name],
    });
  Object.defineProperty(globalThis, "getComputedStyle", {
    configurable: true,
    value: window.getComputedStyle.bind(window),
  });
  Object.defineProperty(globalThis, "requestAnimationFrame", {
    configurable: true,
    value: (callback: FrameRequestCallback) => setTimeout(callback, 0),
  });
  Object.defineProperty(globalThis, "cancelAnimationFrame", {
    configurable: true,
    value: (handle: number) => clearTimeout(handle),
  });
});
afterEach(cleanup);

describe("Finance feed icon picker", () => {
  it("shows decorative category icons and named groups in the accessible popup", async () => {
    const change = mock(() => undefined);
    render(
      <FinanceFeedPicker
        definitions={definitions}
        feedID="industry:pharma"
        companySearch=""
        onFeedChange={change}
      />,
    );
    const trigger = screen.getByRole("combobox", { name: "Finance Feed" });
    expect(
      trigger.querySelector(".lucide-pill")?.getAttribute("aria-hidden"),
    ).toBe("true");
    expect(trigger.textContent).toContain("Pharma");
    fireEvent.click(trigger);
    const selected = await screen.findByRole("option", { name: "Pharma" });
    expect(selected.getAttribute("aria-selected")).toBe("true");
    for (const group of ["All", "Industries", "Groups", "Companies"])
      expect(screen.getByRole("group", { name: group })).toBeDefined();
    for (const [name, icon] of [
      ["Finance", "chart-no-axes-combined"],
      ["Pharma", "pill"],
      ["Technology", "cpu"],
      ["Mag7", "users-round"],
      ["Apple · AAPL · Nasdaq Stock Market (NASDAQ)", "building-2"],
    ]) {
      expect(
        screen
          .getByRole("option", { name })
          .querySelector(`.lucide-${icon}`)
          ?.getAttribute("aria-hidden"),
      ).toBe("true");
    }
    await userEvent.click(screen.getByRole("option", { name: "Mag7" }));
    expect(change).toHaveBeenCalledWith("group:mag7");
    await waitFor(() => expect(screen.queryByRole("listbox")).toBeNull());
  });
  it("preserves the selected listing while filtering other company choices", async () => {
    render(
      <FinanceFeedPicker
        definitions={definitions}
        feedID="instrument:apple"
        companySearch="MSFT"
      />,
    );
    fireEvent.click(screen.getByRole("combobox", { name: "Finance Feed" }));
    expect(
      await screen.findByRole("option", { name: "Apple · AAPL · Nasdaq Stock Market (NASDAQ)" }),
    ).toBeDefined();
    expect(
      screen.getByRole("option", { name: "Microsoft · MSFT · NASDAQ" }),
    ).toBeDefined();
    expect(screen.getByRole("option", { name: "Pharma" })).toBeDefined();
  });
  it("keeps unavailable current feed identity without substituting a catalog choice", async () => {
    const change = mock(() => undefined);
    render(
      <FinanceFeedPicker
        definitions={definitions}
        feedID="instrument:unknown"
        companySearch=""
        onFeedChange={change}
      />,
    );
    expect(
      screen.getByRole("combobox", { name: "Finance Feed" }).textContent,
    ).toContain("Unavailable Feed");
    fireEvent.click(screen.getByRole("combobox", { name: "Finance Feed" }));
    expect(
      (
        await screen.findByRole("option", { name: "Unavailable Feed" })
      ).getAttribute("aria-selected"),
    ).toBe("true");
    expect(change).not.toHaveBeenCalled();
  });
  it("opens from the keyboard, supports typeahead selection and returns focus on Escape", async () => {
    const change = mock(() => undefined);
    const user = userEvent.setup();
    render(
      <FinanceFeedPicker
        definitions={definitions}
        feedID="finance"
        companySearch=""
        onFeedChange={change}
      />,
    );
    const trigger = screen.getByRole("combobox", { name: "Finance Feed" });
    trigger.focus();
    await user.keyboard("{ArrowDown}");
    await screen.findByRole("option", { name: "Pharma" });
    await user.keyboard("tech{Enter}");
    await waitFor(() =>
      expect(change).toHaveBeenCalledWith("industry:technology"),
    );
    await user.click(trigger);
    await screen.findByRole("listbox");
    await user.keyboard("{Escape}");
    await waitFor(() => expect(screen.queryByRole("listbox")).toBeNull());
    expect(document.activeElement).toBe(trigger);
  });
});

it("groups ETFs, crypto, and indices separately from company listings", async () => {
  const assets: FinanceFeedDefinition[] = [
    { id: "instrument:spy", title: "SPY · S&P 500 ETF", kind: "instrument", assetKind: "etf", instrumentIDs: ["spy"], sectorIDs: [], description: "ETF reporting" },
    { id: "instrument:btc", title: "BTC · Bitcoin", kind: "instrument", assetKind: "crypto", instrumentIDs: ["btc"], sectorIDs: [], description: "Crypto reporting" },
    { id: "instrument:spx", title: "SPX · S&P 500", kind: "instrument", assetKind: "index", instrumentIDs: ["spx"], sectorIDs: [], description: "Index reporting" },
  ];
  render(<FinanceFeedPicker definitions={[...definitions, ...assets]} feedID="finance" companySearch="" />);
  await userEvent.click(screen.getByRole("combobox", { name: "Finance Feed" }));
  for (const [group, title] of [["ETFs", assets[0]!.title], ["Crypto", assets[1]!.title], ["Indices", assets[2]!.title]]) {
    expect(screen.getByRole("group", { name: group! }).textContent).toContain(title!);
    expect(screen.getAllByRole("option", { name: title! })).toHaveLength(1);
  }
});
