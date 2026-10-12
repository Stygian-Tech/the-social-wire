import { Suspense } from "react";
import { SocialFeedDirectory } from "@/components/Social/SocialFeedDirectory";
import { SocialTimelineSkeleton } from "@/components/Social/SocialTimelineSkeleton";

export default function Page() {
  return <Suspense fallback={<SocialTimelineSkeleton />}><SocialFeedDirectory /></Suspense>;
}
