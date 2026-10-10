"use client";

import { Rss } from "lucide-react";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Sheet, SheetContent, SheetHeader, SheetTitle, SheetTrigger } from "@/components/ui/sheet";
import { SocialFeeds } from "./SocialFeeds";

export function SocialFeedsSheet() {
  const [open, setOpen] = useState(false);
  return <Sheet open={open} onOpenChange={setOpen}>
    <SheetTrigger render={<Button variant="ghost" size="sm" className="min-h-11 lg:hidden sm:min-h-0" aria-label="Choose Social Feed" />}>
      <Rss aria-hidden="true" />Feeds
    </SheetTrigger>
    <SheetContent side="right" className="overflow-y-auto">
      <SheetHeader><SheetTitle>Social Feeds</SheetTitle></SheetHeader>
      <div className="px-4 pb-4"><SocialFeeds onSelect={() => setOpen(false)} /></div>
    </SheetContent>
  </Sheet>;
}
