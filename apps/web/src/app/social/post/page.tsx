import { Suspense } from "react";
import { SocialPostPage } from "@/components/Social/SocialPostPage";
import { SocialTimelineSkeleton } from "@/components/Social/SocialTimelineSkeleton";

export default function Page() {
  return <Suspense fallback={<SocialTimelineSkeleton />}><SocialPostPage /></Suspense>;
}
