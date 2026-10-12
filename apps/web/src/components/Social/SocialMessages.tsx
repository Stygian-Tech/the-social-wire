"use client";

import { useSearchParams } from "next/navigation";
import { useAuth } from "@/hooks/useAuth";
import { SocialMessagesWorkspace } from "./SocialMessagesWorkspace";

function postDraft(value: string | null): string {
  if (!value) return "";
  try {
    const url = new URL(value);
    if (url.origin !== "https://bsky.app" || url.username || url.password || url.search || url.hash) return "";
    const match = /^\/profile\/([^/]+)\/post\/([^/]+)$/.exec(url.pathname);
    if (!match) return "";
    const actor = decodeURIComponent(match[1]);
    const recordKey = decodeURIComponent(match[2]);
    if (!/^(did:(plc:[a-z2-7]{24}|web:[^\s/?#]+)|[a-z0-9-]+(?:\.[a-z0-9-]+)+)$/.test(actor)) return "";
    if (!/^[a-zA-Z0-9._~:-]{1,512}$/.test(recordKey) || recordKey === "." || recordKey === "..") return "";
    return url.href;
  } catch { return ""; }
}

export function SocialMessages() {
  const { session } = useAuth();
  const draft = postDraft(useSearchParams().get("draft"));
  return session ? <SocialMessagesWorkspace key={`${session.did}:${draft}`} viewerDid={session.did} draft={draft} /> : <p className="p-6 text-sm text-muted-foreground">Log In to View Messages.</p>;
}
