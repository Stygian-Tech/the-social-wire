"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ArrowLeft } from "lucide-react";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { buttonVariants } from "@/components/ui/button";
import { AccountSettingsDialog } from "./AccountSettingsDialog";

export function AccountHeader() {
  const settingsPage = usePathname() === "/me/settings";
  return <FeedHeader title={settingsPage ? "Settings" : "Your Profile"}>
    {settingsPage ? <Link href="/me" className={buttonVariants({ variant: "ghost", size: "icon" })} aria-label="Back to Profile" title="Back to Profile"><ArrowLeft aria-hidden="true" /></Link> : <AccountSettingsDialog />}
  </FeedHeader>;
}
