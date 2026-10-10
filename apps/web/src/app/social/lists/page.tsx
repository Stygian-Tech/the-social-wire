import { Suspense } from "react";
import { SocialLists } from "@/components/Social/SocialLists";
import { SocialTimelineSkeleton } from "@/components/Social/SocialTimelineSkeleton";

export default function Page() {
  return <Suspense fallback={<SocialTimelineSkeleton />}><SocialLists /></Suspense>;
}
