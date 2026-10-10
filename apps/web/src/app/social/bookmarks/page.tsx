import { Suspense } from "react";
import { SocialBookmarks } from "@/components/Social/SocialBookmarks";
import { SocialTimelineSkeleton } from "@/components/Social/SocialTimelineSkeleton";

export default function Page() {
  return <Suspense fallback={<SocialTimelineSkeleton />}><SocialBookmarks /></Suspense>;
}
