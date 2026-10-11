"use client";

import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { safeSocialPostReturnPath, socialPostPageHref } from "@/lib/socialPostNavigation";

export function useSocialPostNavigation() {
  const router = useRouter();
  const pathname = usePathname();
  const params = useSearchParams();
  function origin() {
    if (pathname === "/social/post") return safeSocialPostReturnPath(params?.get("returnTo"));
    const query = params?.toString();
    return safeSocialPostReturnPath(`${pathname ?? "/social"}${query ? `?${query}` : ""}${typeof window === "undefined" ? "" : window.location.hash}`);
  }
  return { openPost: (uri: string) => router.push(socialPostPageHref(uri, origin())), back: () => router.replace(origin(), { scroll: false }) };
}
