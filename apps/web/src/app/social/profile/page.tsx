import { Suspense } from "react";
import { SocialProfilePage } from "@/components/Social/SocialProfilePage";
import { SocialTimelineSkeleton } from "@/components/Social/SocialTimelineSkeleton";

export default function ProfilePage() {
  return <Suspense fallback={<SocialTimelineSkeleton />}><SocialProfilePage /></Suspense>;
}
