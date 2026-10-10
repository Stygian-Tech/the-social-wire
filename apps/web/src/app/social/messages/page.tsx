import { Suspense } from "react";
import { SocialMessages } from "@/components/Social/SocialMessages";
import { SocialTimelineSkeleton } from "@/components/Social/SocialTimelineSkeleton";

export default function Page() {
  return <Suspense fallback={<SocialTimelineSkeleton />}><SocialMessages /></Suspense>;
}
