import { Suspense } from "react";
import { SocialDrafts } from "@/components/Social/SocialDrafts";
import { SocialTimelineSkeleton } from "@/components/Social/SocialTimelineSkeleton";

export default function Page() {
  return <Suspense fallback={<SocialTimelineSkeleton />}><SocialDrafts /></Suspense>;
}
