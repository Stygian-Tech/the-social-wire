import { afterEach, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { renderHook } from "@testing-library/react";
import * as Next from "next/navigation";
import * as Auth from "@/hooks/useAuth";
import { useSocialThreadNavigation } from "@/hooks/useSocialThreadNavigation";
const uri = "at://did:plc:author/app.bsky.feed.post/root";
const deep = `${uri}deep`;
const deeper = `${uri}deeper`;
let params: URLSearchParams;
let did: string;
const push = mock((href: string, options?: unknown) => { void href; void options; }); const replace = mock((href: string, options?: unknown) => { void href; void options; });
const restores: (() => void)[] = [];
beforeEach(() => {
  did = `did:plc:thread-${crypto.randomUUID()}`; params = new URLSearchParams({ uri, returnTo: "/social?feed=original" }); push.mockClear(); replace.mockClear();
  const router = spyOn(Next, "useRouter").mockReturnValue({ push, replace } as unknown as ReturnType<typeof Next.useRouter>);
  const path = spyOn(Next, "usePathname").mockReturnValue("/social/post");
  const search = spyOn(Next, "useSearchParams").mockImplementation(() => params as ReturnType<typeof Next.useSearchParams>);
  const auth = spyOn(Auth, "useAuth").mockImplementation(() => ({ session: { did } }) as ReturnType<typeof Auth.useAuth>);
  restores.push(() => router.mockRestore(), () => path.mockRestore(), () => search.mockRestore(), () => auth.mockRestore());
});
afterEach(() => restores.splice(0).reverse().forEach(fn => fn()));
function container(target = deep) {
  const element = document.createElement("div"); const anchor = document.createElement("div");
  anchor.dataset.threadPostUri = target; element.append(anchor); element.scrollTop = 700;
  element.getBoundingClientRect = () => ({ top: 50 }) as DOMRect;
  anchor.getBoundingClientRect = () => ({ top: 150 }) as DOMRect;
  return { element, anchor };
}
function navigate(href: string) { params = new URL(href, "https://socialwire.invalid").searchParams; }
describe("deep thread navigation", () => {
  it("opens a focused root and Back restores the source route and anchor offset", () => {
    const { result, rerender } = renderHook(useSocialThreadNavigation); const { element, anchor } = container();
    result.current.openThread(deep, element);
    expect(push).toHaveBeenCalledTimes(1);
    navigate(push.mock.calls[0]![0] as string); rerender(); expect(params.get("uri")).toBe(deep); expect(result.current.focused).toBe(true);
    result.current.back(); navigate(replace.mock.calls[0]![0] as string); rerender();
    expect(params.get("uri")).toBe(uri); expect(params.get("returnTo")).toBe("/social?feed=original"); expect(result.current.focused).toBe(false);
    element.scrollTop = 0; anchor.getBoundingClientRect = () => ({ top: 850 }) as DOMRect;
    expect(result.current.restore(element)).toBe(true); expect(element.scrollTop).toBe(700);
  });
  it("returns keyboard focus to the original Show More control", () => {
    const { result, rerender } = renderHook(useSocialThreadNavigation); const { element, anchor } = container();
    const button = document.createElement("button"); button.dataset.threadShowMore = ""; anchor.append(button); document.body.append(element);
    try {
      result.current.openThread(deep, element); navigate(push.mock.calls[0]![0]); rerender();
      result.current.back(); navigate(replace.mock.calls[0]![0]); rerender(); result.current.restore(element);
      expect(document.activeElement).toBe(button);
    } finally { element.remove(); }
  });
  it("supports two drill-downs and returns one level at a time", () => {
    const { result, rerender } = renderHook(useSocialThreadNavigation);
    result.current.openThread(deep, container().element); navigate(push.mock.calls[0]![0] as string); rerender();
    result.current.openThread(deeper, container(deeper).element); navigate(push.mock.calls[1]![0] as string); rerender();
    result.current.back(); navigate(replace.mock.calls[0]![0] as string); rerender();
    expect(params.get("uri")).toBe(deep); expect(result.current.focused).toBe(true);
    result.current.back(); navigate(replace.mock.calls[1]![0] as string); rerender(); expect(params.get("uri")).toBe(uri);
  });
  it("restores browser Back through pending origin state and falls back when the anchor is absent", () => {
    const { result, rerender } = renderHook(useSocialThreadNavigation); result.current.openThread(deep, container().element);
    navigate(push.mock.calls[0]![0] as string); rerender();
    params = new URLSearchParams({ uri, returnTo: "/social?feed=original" }); rerender();
    const empty = document.createElement("div"); result.current.restore(empty); expect(empty.scrollTop).toBe(700);
  });
  it("never uses another viewer's return token and safely exits a direct focused link", () => {
    const { result, rerender } = renderHook(useSocialThreadNavigation); result.current.openThread(deep, container().element);
    navigate(push.mock.calls[0]![0] as string); did = "did:plc:another"; rerender(); result.current.back();
    expect(replace).toHaveBeenLastCalledWith("/social?feed=original");
    params = new URLSearchParams({ uri: deep, focusThread: "1", returnTo: "//evil.test" }); rerender(); result.current.back();
    expect(replace).toHaveBeenLastCalledWith("/social");
  });
});
