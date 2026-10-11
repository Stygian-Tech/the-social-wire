"use client";

import { useRouter, useSearchParams } from "next/navigation";
import { useAuth } from "./useAuth";
import { useSocialPostNavigation } from "./useSocialPostNavigation";
import { isSocialPostUri, safeSocialPostReturnPath } from "@/lib/socialPostNavigation";
import { consumePendingSocialThreadReturn, readSocialThreadReturnPoint, saveSocialThreadReturnPoint, socialFocusedThreadHref } from "@/lib/socialThreadNavigation";

export function useSocialThreadNavigation() {
  const router = useRouter();
  const params = useSearchParams();
  const { session } = useAuth();
  const navigation = useSocialPostNavigation();
  const uri = params?.get("uri");
  const token = params?.get("threadReturn");
  const focused = params?.get("focusThread") === "1";
  const returnTo = safeSocialPostReturnPath(params?.get("returnTo"));
  const findAnchor = (container: HTMLElement, target: string) => [...container.querySelectorAll<HTMLElement>("[data-thread-post-uri]")].find(node => node.dataset.threadPostUri === target);

  function openThread(target: string, container: HTMLElement | null) {
    if (!session || !isSocialPostUri(uri)) return;
    const anchor = container ? findAnchor(container, target) : undefined;
    const parentToken = readSocialThreadReturnPoint(session.did, token) ? token! : undefined;
    const nextToken = saveSocialThreadReturnPoint(session.did, { uri, returnTo, parentToken, focused, scrollTop: container?.scrollTop ?? 0, anchorUri: target, anchorOffset: anchor && container ? anchor.getBoundingClientRect().top - container.getBoundingClientRect().top : 0 });
    router.push(socialFocusedThreadHref(target, returnTo, nextToken), { scroll: false });
  }

  function back() {
    const point = session ? readSocialThreadReturnPoint(session.did, token) : undefined;
    if (!point) { navigation.back(); return; }
    router.replace(socialFocusedThreadHref(point.uri, point.returnTo, point.parentToken, token!, point.focused), { scroll: false });
  }

  function restore(container: HTMLElement | null): boolean {
    if (!container || !session || !isSocialPostUri(uri)) return false;
    const explicit = readSocialThreadReturnPoint(session.did, params?.get("threadRestore"));
    const pending = consumePendingSocialThreadReturn(session.did, uri, token ?? undefined);
    const point = explicit?.uri === uri && explicit.parentToken === (token ?? undefined) && explicit.focused === focused ? explicit : pending;
    if (!point) return true;
    const anchor = findAnchor(container, point.anchorUri);
    container.scrollTop = anchor ? container.scrollTop + anchor.getBoundingClientRect().top - container.getBoundingClientRect().top - point.anchorOffset : point.scrollTop;
    anchor?.querySelector<HTMLButtonElement>("[data-thread-show-more]")?.focus({ preventScroll: true });
    return true;
  }

  return { openThread, back, restore, focused };
}
