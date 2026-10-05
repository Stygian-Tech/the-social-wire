import { afterEach, beforeAll, describe, expect, it } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { FinanceFollowingSidebar } from "@/components/FinanceFollowingSidebar";
import type { FinanceFeedDefinition, FinanceSelection } from "@/lib/financeFeedClient";
beforeAll(()=>{for(const name of ["HTMLElement","Element","Node","DOMRect"] as const)Object.defineProperty(globalThis,name,{configurable:true,value:window[name]});});
afterEach(cleanup);
const definitions:FinanceFeedDefinition[]=[{id:"instrument:apple",title:"$AAPL · Apple · Nasdaq Stock Market (NASDAQ)",kind:"instrument",instrumentIDs:["apple"],sectorIDs:[],description:"Apple"},{id:"instrument:msft",title:"$MSFT · Microsoft · NASDAQ",kind:"instrument",instrumentIDs:["msft"],sectorIDs:[],description:"Microsoft"},{id:"industry:tech",title:"Technology",kind:"industry",instrumentIDs:[],sectorIDs:["tech"],description:"Tech"}];
const selections:FinanceSelection[]=[{kind:"instrument",reference:"apple",createdAt:"now",updatedAt:"now"},{kind:"instrument",reference:"unknown",createdAt:"now",updatedAt:"now"},{kind:"sector",reference:"tech",createdAt:"now",updatedAt:"now"}];
describe("Followed Finance interests",()=>{
 it("shows only catalog-backed followed securities and preserves shareable links",()=>{render(<FinanceFollowingSidebar definitions={definitions} selections={selections} feedID="instrument:apple"/>);const row=screen.getByRole("link",{name:"$AAPL · Apple"});expect(row.getAttribute("href")).toBe("/read?feed=finance&financeFeed=instrument%3Aapple");expect(row.getAttribute("aria-current")).toBe("page");expect(screen.queryByText(/Nasdaq Stock Market/)).toBeNull();expect(screen.queryByRole("link",{name:/Microsoft/})).toBeNull();expect(screen.getByRole("link",{name:"Technology"}).getAttribute("href")).toBe("/read?feed=finance&financeFeed=industry%3Atech");expect(screen.getByRole("link",{name:"All Finance"}).getAttribute("href")).toBe("/read?feed=finance");});
 it("uses in-place feed navigation for primary clicks",()=>{const changed:string[]=[];render(<FinanceFollowingSidebar definitions={definitions} selections={selections} feedID="finance" onFeedChange={id=>changed.push(id)}/>);fireEvent.click(screen.getByRole("link",{name:"$AAPL · Apple"}));expect(changed).toEqual(["instrument:apple"]);});
 it("distinguishes loading and failed reconciliation from empty interests",()=>{const view=render(<FinanceFollowingSidebar definitions={definitions} selections={[]} feedID="finance" loading/>);expect(screen.getByText("Loading Your Interests…")).toBeTruthy();expect(screen.queryByText(/Add sectors or securities/)).toBeNull();view.rerender(<FinanceFollowingSidebar definitions={definitions} selections={[]} feedID="finance" error/>);expect(screen.getByText(/could not load/)).toBeTruthy();expect(screen.queryByText(/Add sectors or securities/)).toBeNull();});
 it("shows sector-only interests with selection highlighting and no empty guidance",()=>{
   render(<FinanceFollowingSidebar definitions={definitions} selections={selections.filter(selection=>selection.kind==="sector")} feedID="industry:tech"/>);
   expect(screen.getByRole("heading",{name:"Sectors"})).toBeTruthy();
   expect(screen.queryByRole("heading",{name:"Securities"})).toBeNull();
   expect(screen.getByRole("link",{name:"Technology"}).getAttribute("aria-current")).toBe("page");
   expect(screen.queryByText(/Add sectors or securities/)).toBeNull();
 });
 it("uses canonical sector references and excludes unfollowed or non-sector feeds",()=>{
   const extra:FinanceFeedDefinition[]=[
     {id:"industry:energy",title:"Energy",kind:"industry",instrumentIDs:[],sectorIDs:["energy"],description:"Energy"},
     {id:"group:tech",title:"Tech Group",kind:"group",instrumentIDs:[],sectorIDs:["tech"],description:"Group"},
     {id:"industry:mixed",title:"Mixed Sectors",kind:"industry",instrumentIDs:[],sectorIDs:["tech","energy"],description:"Mixed"},
   ];
   const view=render(<FinanceFollowingSidebar definitions={[...definitions,...extra]} selections={[{kind:"sector",reference:"unknown",createdAt:"now",updatedAt:"now"}]} feedID="finance"/>);
   expect(screen.queryByRole("link",{name:"Technology"})).toBeNull();
   expect(screen.getByText(/Add sectors or securities/)).toBeTruthy();
   view.rerender(<FinanceFollowingSidebar definitions={[...definitions,...extra]} selections={selections} feedID="finance"/>);
   expect(screen.getByRole("link",{name:"Technology"})).toBeTruthy();
   for(const name of ["Energy","Tech Group","Mixed Sectors"])expect(screen.queryByRole("link",{name})).toBeNull();
 });
 it("sorts sectors and updates them when follows change",()=>{
   const extra:FinanceFeedDefinition={id:"industry:energy",title:"Energy",kind:"industry",instrumentIDs:[],sectorIDs:["energy"],description:"Energy"};
   const view=render(<FinanceFollowingSidebar definitions={[...definitions,extra]} selections={[...selections,{kind:"sector",reference:"energy",createdAt:"now",updatedAt:"now"}]} feedID="finance"/>);
   expect(screen.getAllByRole("link").map(link=>link.textContent)).toEqual(["All Finance","Energy","Technology","$AAPL · Apple"]);
   view.rerender(<FinanceFollowingSidebar definitions={[...definitions,extra]} selections={[]} feedID="finance"/>);
   expect(screen.queryByRole("heading",{name:"Sectors"})).toBeNull();
   expect(screen.queryByRole("link",{name:"Technology"})).toBeNull();
 });
 it("navigates sectors in place while retaining modified-click browser navigation",()=>{
   const changed:string[]=[];
   render(<FinanceFollowingSidebar definitions={definitions} selections={selections} feedID="finance" onFeedChange={id=>changed.push(id)}/>);
   const row=screen.getByRole("link",{name:"Technology"});
   fireEvent.click(row,{ctrlKey:true});
   expect(changed).toEqual([]);
   fireEvent.click(row);
   expect(changed).toEqual(["industry:tech"]);
 });
});

it("uses the full viewport for its independent scrolling rail", () => {
 render(<FinanceFollowingSidebar definitions={definitions} selections={selections} feedID="finance" />);
 expect(screen.getByRole("complementary").className).toContain("xl:max-h-[calc(100svh-var(--environment-banner-height,0px)-3rem)]");
});
