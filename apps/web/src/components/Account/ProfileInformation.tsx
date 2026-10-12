"use client";

import { useViewerProfile } from "@/hooks/useViewerProfile";
import { ProfileHeader } from "./ProfileHeader";

export function ProfileInformation() {
  const profile = useViewerProfile();
  return <ProfileHeader viewer={profile.data} loading={profile.isLoading} onRetry={() => { void profile.refetch(); }} />;
}
