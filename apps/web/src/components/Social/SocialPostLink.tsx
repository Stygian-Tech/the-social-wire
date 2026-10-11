"use client";

import type { ModerationOpts } from "@atproto/api";
import { useSocialPostNavigation } from "@/hooks/useSocialPostNavigation";
import { isSocialPostUri } from "@/lib/socialPostNavigation";

export function SocialPostLink({ uri }: { uri: string; moderation: ModerationOpts }) {
  const navigation = useSocialPostNavigation();
  return isSocialPostUri(uri) ? <button type="button" className="text-left text-sm text-primary hover:underline" onClick={() => navigation.openPost(uri)}>Open Post</button> : null;
}
