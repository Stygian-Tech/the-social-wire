import { Suspense } from "react";
import { SocialExplore } from "@/components/Social/SocialExplore";
import { SocialTimelineSkeleton } from "@/components/Social/SocialTimelineSkeleton";

export default function Page() {
  return <Suspense fallback={<SocialTimelineSkeleton />}><SocialExplore /></Suspense>;
}
