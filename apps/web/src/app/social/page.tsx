import { Suspense } from "react";
import { SocialTimeline } from "@/components/Social/SocialTimeline";
import { SocialTimelineSkeleton } from "@/components/Social/SocialTimelineSkeleton";

export default function SocialPage() {
  return <Suspense fallback={<SocialTimelineSkeleton />}><SocialTimeline /></Suspense>;
}
