import { afterEach, expect, it, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { PodcastChapters } from "@/components/Podcasts/PodcastChapters";
import { PodcastChapterTimeline } from "@/components/Podcasts/PodcastChapterTimeline";
import { PodcastShowDetails } from "@/components/Podcasts/PodcastShowDetails";
import { PodcastArtwork } from "@/components/Podcasts/PodcastArtwork";
import * as auth from "@/hooks/useAuth";
import * as gateway from "@/lib/socialWireGatewayClient";
import type { OAuthSession } from "@atproto/oauth-client-browser";
const restores: (() => void)[] = [];
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });
it("retries Transistor publisher artwork before using the placeholder and resets for another show", () => {
  const original = "https://img-upload-production.transistor.fm/show/48255/1704319857-artwork.jpg";
  const cdn = `https://img.transistorcdn.com/signature/mb:500000/${btoa(original).replace(/=+$/, "")}.jpg`;
  const view = render(<PodcastArtwork src={cdn} alt="Primary Technology" />);
  fireEvent.error(screen.getByRole("img", { name: "Primary Technology" }));
  expect(screen.getByRole("img", { name: "Primary Technology" }).getAttribute("src")).toBe(original);
  fireEvent.error(screen.getByRole("img", { name: "Primary Technology" }));
  expect(screen.getByRole("img", { name: "Primary Technology" }).getAttribute("src")).toBeNull();
  view.rerender(<PodcastArtwork src="https://example.com/new.jpg" alt="Other Show" />);
  expect(screen.getByRole("img", { name: "Other Show" }).getAttribute("src")).toBe("https://example.com/new.jpg");
});
it("shows publisher artwork and available host photos without inventing missing hosts", () => {
  const view = render(<PodcastShowDetails show={{ id:"show",title:"Test Show",sourceKind:"rss",artworkUrl:"https://example.com/show.jpg",hosts:[{name:"Sam",imageUrl:"https://example.com/sam.jpg"},{name:"Jo"}] }} />);
  expect(screen.getByRole("img",{name:"Test Show Artwork"}).getAttribute("src")).toBe("https://example.com/show.jpg");
  expect(screen.getByRole("img",{name:"Sam Photo"})).toBeTruthy();
  expect(screen.getByText("Jo")).toBeTruthy();
  view.rerender(<PodcastShowDetails show={{ id:"show",title:"Test Show",sourceKind:"rss" }} />);
  expect(screen.queryByLabelText("Podcast Hosts")).toBeNull();
});
it("chapter selection keeps original timestamps and follows chapter boundaries", () => {
  const seeks: number[] = [];
  const chapters = [{startSeconds:90,title:"Second"},{startSeconds:0,title:"Opening"},{startSeconds:-1,title:"Invalid"}];
  const view = render(<PodcastChapters chapters={chapters} position={89.9} onSeek={time => seeks.push(time)} />);
  expect(screen.queryByText("Invalid")).toBeNull();
  expect(screen.getByRole("button",{name:/Opening/}).getAttribute("aria-current")).toBe("true");
  fireEvent.click(screen.getByRole("button",{name:/Second/}));
  expect(seeks).toEqual([90]);
  view.rerender(<PodcastChapters chapters={chapters} position={90} onSeek={time => seeks.push(time)} />);
  expect(screen.getByRole("button",{name:/Second/}).getAttribute("aria-current")).toBe("true");
});
it("the player chapter list shows chapter art, falls back to episode then show art, and preserves sorted seeks", () => {
  const seeks: number[] = [];
  render(<PodcastChapterTimeline chapters={[
    {startSeconds:90,title:"Second"},
    {startSeconds:0,title:"Opening",artworkUrl:"https://example.com/chapter.jpg"},
    {startSeconds:400,title:"Outside Episode",artworkUrl:"https://example.com/outside.jpg"},
  ]} artworkSources={["https://example.com/episode.jpg","https://example.com/show.jpg"]} duration={300} position={0} seek={time => seeks.push(time)} />);
  fireEvent.click(screen.getByText("Chapters (2)"));
  const list = screen.getByRole("list");
  const buttons = within(list).getAllByRole("button");
  expect(buttons.map(button => button.textContent)).toEqual(["Opening0:00","Second1:30"]);
  expect(screen.queryByText("Outside Episode")).toBeNull();
  const image = buttons[0]!.querySelector("img")!;
  expect(image.getAttribute("src")).toBe("https://example.com/chapter.jpg");
  expect(image.getAttribute("width")).toBe("32");
  expect(buttons[1]!.querySelector("img")?.getAttribute("src")).toBe("https://example.com/episode.jpg");
  fireEvent.error(image);
  expect(buttons[0]!.querySelector("img")?.getAttribute("src")).toBe("https://example.com/episode.jpg");
  fireEvent.error(buttons[0]!.querySelector("img")!);
  expect(buttons[0]!.querySelector("img")?.getAttribute("src")).toBe("https://example.com/show.jpg");
  fireEvent.click(within(list).getByRole("button",{name:/Second/}));
  expect(seeks).toEqual([90]);
});
it("the dialog chapter list uses chapter artwork and shared episode or show fallbacks", () => {
  render(<PodcastChapters chapters={[
    {startSeconds:0,title:"Opening",artworkUrl:"https://example.com/chapter.jpg"},
    {startSeconds:90,title:"Second"},
  ]} artworkSources={[undefined,"https://example.com/show.jpg"]} position={0} onSeek={() => {}} />);
  const opening = screen.getByRole("button",{name:/Opening/});
  expect(opening.querySelector("img")?.getAttribute("src")).toBe("https://example.com/chapter.jpg");
  fireEvent.error(opening.querySelector("img")!);
  expect(opening.querySelector("img")?.getAttribute("src")).toBe("https://example.com/show.jpg");
  expect(screen.getByRole("button",{name:/Second/}).querySelector("img")?.getAttribute("src")).toBe("https://example.com/show.jpg");
  expect(opening.getAttribute("aria-current")).toBe("true");
});
it("private artwork uses viewer-authenticated bytes and revokes them on account changes", async () => {
  let did = "did:plc:viewer-a";
  const oauth = {} as OAuthSession;
  const getOAuthSession = () => oauth;
  const session = spyOn(auth,"useAuth").mockImplementation(() => ({session:{did},getOAuthSession}) as ReturnType<typeof auth.useAuth>);
  const fetch = spyOn(gateway,"gatewayFetch").mockResolvedValue(new Response(new Blob(["image"],{type:"image/png"})));
  const createDescriptor = Object.getOwnPropertyDescriptor(URL,"createObjectURL");
  const revokeDescriptor = Object.getOwnPropertyDescriptor(URL,"revokeObjectURL");
  const revoked: string[] = [];
  Object.defineProperty(URL,"createObjectURL",{configurable:true,value:()=>`blob:${did}`});
  Object.defineProperty(URL,"revokeObjectURL",{configurable:true,value:(url:string)=>revoked.push(url)});
  restores.push(()=>session.mockRestore(),()=>fetch.mockRestore(),()=> {
    if(createDescriptor) Object.defineProperty(URL,"createObjectURL",createDescriptor); else Reflect.deleteProperty(URL,"createObjectURL");
    if(revokeDescriptor) Object.defineProperty(URL,"revokeObjectURL",revokeDescriptor); else Reflect.deleteProperty(URL,"revokeObjectURL");
  });
  const view = render(<PodcastArtwork src="/v1/podcasts/image?showId=private&kind=artwork" alt="Private Artwork" size={64} />);
  await waitFor(()=>expect(screen.getByRole("img",{name:"Private Artwork"}).getAttribute("src")).toBe("blob:did:plc:viewer-a"));
  expect(fetch.mock.calls[0]?.[0]).toBe(oauth);
  did="did:plc:viewer-b";
  fetch.mockImplementation(()=>new Promise(()=>{}));
  view.rerender(<PodcastArtwork src="/v1/podcasts/image?showId=private&kind=artwork" alt="Private Artwork" size={64} />);
  expect(screen.getByRole("img",{name:"Private Artwork"}).getAttribute("src")).toBeNull();
  expect(revoked).toContain("blob:did:plc:viewer-a");
});
