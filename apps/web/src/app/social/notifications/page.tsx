import { Suspense } from "react";
import { SocialNotifications } from "@/components/Social/SocialNotifications";
import { SocialTimelineSkeleton } from "@/components/Social/SocialTimelineSkeleton";

export default function Page() {
  return <Suspense fallback={<SocialTimelineSkeleton />}><SocialNotifications /></Suspense>;
}
