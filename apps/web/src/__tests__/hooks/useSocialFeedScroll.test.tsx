import { afterEach, expect, it } from "bun:test";
import { cleanup, fireEvent, render } from "@testing-library/react";
import { useSocialFeedScroll } from "@/hooks/useSocialFeedScroll";
import { rememberSocialFeedScroll, restoreSocialFeedScroll } from "@/lib/socialFeedScroll";

afterEach(cleanup);

function Feed({ did, feed = "following", ready = true }: { did: string; feed?: string; ready?: boolean }) {
  const ref = useSocialFeedScroll(did, feed, ready);
  return <div ref={ref} data-testid="feed" key={`${did}:${feed}`} />;
}

it("restores inner feed scrolling after leaving for a post and waits until content is ready", () => {
  const did = `did:plc:${crypto.randomUUID()}`;
  const first = render(<Feed did={did} />);
  const original = first.getByTestId("feed");
  original.scrollTop = 720;
  fireEvent.scroll(original);
  first.unmount();
  const returned = render(<Feed did={did} ready={false} />);
  const node = returned.getByTestId("feed");
  expect(node.scrollTop).toBe(0);
  returned.rerender(<Feed did={did} />);
  expect(node.scrollTop).toBe(720);
  node.scrollTop = 860;
  fireEvent.scroll(node);
  returned.unmount();
  expect(render(<Feed did={did} />).getByTestId("feed").scrollTop).toBe(860);
});

it("isolates positions across feed selections and signed-in accounts", () => {
  const did = `did:plc:${crypto.randomUUID()}`;
  const view = render(<Feed did={did} />);
  const original = view.getByTestId("feed");
  original.scrollTop = 640;
  fireEvent.scroll(original);
  view.rerender(<Feed did={did} feed="custom:one" />);
  expect(view.getByTestId("feed").scrollTop).toBe(0);
  view.getByTestId("feed").scrollTop = 310;
  fireEvent.scroll(view.getByTestId("feed"));
  view.rerender(<Feed did={`${did}other`} />);
  expect(view.getByTestId("feed").scrollTop).toBe(0);
  view.rerender(<Feed did={did} />);
  expect(view.getByTestId("feed").scrollTop).toBe(640);
  view.rerender(<Feed did={did} feed="custom:one" />);
  expect(view.getByTestId("feed").scrollTop).toBe(310);
});

it("restores the visible post offset when earlier rows change height and falls back if it disappears", () => {
  const did = `did:plc:${crypto.randomUUID()}`;
  const node = document.createElement("div");
  const previous = document.createElement("article");
  const anchor = document.createElement("article");
  previous.dataset.analyticsSubject = "at://did:plc:author/app.bsky.feed.post/previous";
  anchor.dataset.analyticsSubject = "at://did:plc:author/app.bsky.feed.post/visible";
  node.append(previous, anchor);
  node.getBoundingClientRect = () => ({ top: 50 }) as DOMRect;
  previous.getBoundingClientRect = () => ({ top: -200, bottom: 30 }) as DOMRect;
  anchor.getBoundingClientRect = () => ({ top: 30, bottom: 350 }) as DOMRect;
  node.scrollTop = 700;
  rememberSocialFeedScroll(did, "following", node);
  node.scrollTop = 0;
  anchor.getBoundingClientRect = () => ({ top: 930, bottom: 1250 }) as DOMRect;
  restoreSocialFeedScroll(did, "following", node);
  expect(node.scrollTop).toBe(900);
  anchor.remove();
  node.scrollTop = 0;
  restoreSocialFeedScroll(did, "following", node);
  expect(node.scrollTop).toBe(700);
});

it("keeps scroll history bounded", () => {
  const did = `did:plc:${crypto.randomUUID()}`;
  const node = document.createElement("div");
  node.scrollTop = 500;
  rememberSocialFeedScroll(did, "first", node);
  for (let i = 0; i < 20; i++) rememberSocialFeedScroll(did, `feed:${i}`, node);
  node.scrollTop = 0;
  restoreSocialFeedScroll(did, "first", node);
  expect(node.scrollTop).toBe(0);
});
