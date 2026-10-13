"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ArrowLeft } from "lucide-react";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { buttonVariants } from "@/components/ui/button";
import { AccountSettingsDialog } from "./AccountSettingsDialog";
import { useAuth } from "@/hooks/useAuth";
import { SocialProfileLink } from "@/components/Social/SocialProfileLink";

export function AccountHeader() {
  const settingsPage = usePathname() === "/me/settings";
  const { session } = useAuth();
  return <FeedHeader title={settingsPage ? "Settings" : "Your Profile"}>
    {settingsPage ? session ? <SocialProfileLink actor={session.did} href="/me" className={buttonVariants({ variant: "ghost", size: "icon" })} aria-label="Back to Profile" title="Back to Profile"><ArrowLeft aria-hidden="true" /></SocialProfileLink> : <Link href="/me" className={buttonVariants({ variant: "ghost", size: "icon" })} aria-label="Back to Profile" title="Back to Profile"><ArrowLeft aria-hidden="true" /></Link> : <AccountSettingsDialog />}
  </FeedHeader>;
}
