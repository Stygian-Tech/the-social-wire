import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { FinanceTradingView } from "@/components/FinanceTradingView";
const originalFlag=process.env.NEXT_PUBLIC_FINANCE_WIDGETS_ENABLED;
const originalObserver=globalThis.IntersectionObserver;
beforeEach(()=>{
 process.env.NEXT_PUBLIC_FINANCE_WIDGETS_ENABLED="true";
 document.documentElement.classList.remove("dark");
 Object.defineProperty(globalThis,"IntersectionObserver",{configurable:true,value:class {
  constructor(private callback:(rows:{isIntersecting:boolean}[])=>void){}
  observe(){this.callback([{isIntersecting:true}]);}
  disconnect(){}
 }});
});
afterEach(()=>{cleanup();process.env.NEXT_PUBLIC_FINANCE_WIDGETS_ENABLED=originalFlag;Object.defineProperty(globalThis,"IntersectionObserver",{configurable:true,value:originalObserver});document.documentElement.classList.remove("dark");});
describe("TradingView presentation",()=>{
 it("does not create third-party scripts when hidden, disabled, or unsupported",()=>{
  const {rerender,container}=render(<FinanceTradingView symbol="NASDAQ:AAPL" hidden widgetsEnabled/>);
  expect(container.querySelector("script")).toBeNull();
  rerender(<FinanceTradingView symbol="NASDAQ:AAPL" hidden={false} widgetsEnabled={false}/>);
  expect(container.querySelector("script")).toBeNull();
  rerender(<FinanceTradingView symbol="unverified" hidden={false} widgetsEnabled/>);
  expect(container.querySelector("script")).toBeNull();
 });
 it("uses official markup and reloads the embed after theme changes",async()=>{
  const {container}=render(<FinanceTradingView symbol="NASDAQ:AAPL" hidden={false} widgetsEnabled/>);
  await waitFor(()=>expect(container.querySelector("script")).not.toBeNull());
  expect(container.querySelector(".tradingview-widget-container__widget")).not.toBeNull();
  expect(container.querySelector(".tradingview-widget-copyright a")?.getAttribute("href")).toBe("https://www.tradingview.com/");
  expect(JSON.parse(container.querySelector("script")!.textContent!).symbols).toEqual([["NASDAQ:AAPL|1D"]]);
  expect(JSON.parse(container.querySelector("script")!.textContent!).colorTheme).toBe("light");
  document.documentElement.classList.add("dark");
  await waitFor(()=>expect(JSON.parse(container.querySelector("script")!.textContent!).colorTheme).toBe("dark"));
  expect(container.querySelectorAll("script")).toHaveLength(1);
 });
 it("reports embed failure while preserving the article container",async()=>{
  const {container}=render(<><p>Article Body</p><FinanceTradingView symbol="NASDAQ:AAPL" hidden={false} widgetsEnabled/></>);
  await waitFor(()=>expect(container.querySelector("script")).not.toBeNull());
  fireEvent.error(container.querySelector("script")!);
  expect(screen.getByRole("status").textContent).toContain("continue reading");
  expect(screen.getByText("Article Body")).not.toBeNull();
 });
});
