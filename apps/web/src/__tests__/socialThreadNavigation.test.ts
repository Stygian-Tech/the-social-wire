import { describe, expect, it } from "bun:test";
import { consumePendingSocialThreadReturn, readSocialThreadReturnPoint, saveSocialThreadReturnPoint, socialFocusedThreadHref, type SocialThreadReturnPoint } from "@/lib/socialThreadNavigation";
const uri = "at://did:plc:author/app.bsky.feed.post/root";
const anchorUri = "at://did:plc:author/app.bsky.feed.post/deep";
const point: SocialThreadReturnPoint = { uri, anchorUri, anchorOffset: 100, scrollTop: 700, focused: false, returnTo: "/social?feed=original" };
describe("deep thread return points", () => {
  it("keeps exact origin and scroll independently for each viewer", () => {
    const token = saveSocialThreadReturnPoint("did:plc:nav1", point);
    expect(readSocialThreadReturnPoint("did:plc:nav1", token)).toEqual(point);
    expect(readSocialThreadReturnPoint("did:plc:other", token)).toBeUndefined();
    expect(readSocialThreadReturnPoint("did:plc:nav1", "../bad")).toBeUndefined();
    expect(consumePendingSocialThreadReturn("did:plc:nav1", uri)).toEqual(point);
    expect(consumePendingSocialThreadReturn("did:plc:nav1", uri)).toBeUndefined();
  });
  it("keeps nested returns bounded without recursively embedding URLs", () => {
    const first = saveSocialThreadReturnPoint("did:plc:nav2", point);
    const nested = { ...point, uri: anchorUri, anchorUri: `${anchorUri}deeper`, focused: true, parentToken: first };
    const second = saveSocialThreadReturnPoint("did:plc:nav2", nested);
    const href = socialFocusedThreadHref(nested.anchorUri, nested.returnTo, second);
    const params = new URL(href, "https://socialwire.invalid").searchParams;
    expect(params.get("threadReturn")).toBe(second);
    expect(params.get("focusThread")).toBe("1");
    expect(readSocialThreadReturnPoint("did:plc:nav2", second)?.parentToken).toBe(first);
    expect(href.length).toBeLessThan(300);
    expect(consumePendingSocialThreadReturn("did:plc:nav2", anchorUri, first)).toEqual(nested);
  });
  it("bounds saved history and rejects unsafe destinations and invalid positions", () => {
    const did = "did:plc:nav3";
    const first = saveSocialThreadReturnPoint(did, point);
    for (let i = 0; i < 20; i++) saveSocialThreadReturnPoint(did, point);
    expect(readSocialThreadReturnPoint(did, first)).toBeUndefined();
    for (const bad of [{ returnTo: "https://evil.test" }, { scrollTop: -1 }, { scrollTop: NaN }, { anchorOffset: Infinity }, { parentToken: "../no" }, { uri: "at://bad" }]) {
      expect(() => saveSocialThreadReturnPoint(did, { ...point, ...bad })).toThrow();
    }
    const params = new URL(socialFocusedThreadHref(anchorUri, "//evil.test", "../bad"), "https://socialwire.invalid").searchParams;
    expect(params.get("returnTo")).toBe("/social");
    expect(params.get("threadReturn")).toBeNull();
  });
});
