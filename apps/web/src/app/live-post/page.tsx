import { Suspense } from "react";
import { LivePostsWorkspace } from "@/components/LivePosts/LivePostsWorkspace";

export default function LivePostPage() {
  return <Suspense fallback={<p role="status">Loading Live Post…</p>}><LivePostsWorkspace /></Suspense>;
}
