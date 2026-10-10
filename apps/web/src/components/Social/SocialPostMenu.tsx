"use client";

import { useState } from "react";
import Link from "next/link";
import { Copy, MoreHorizontal, Send } from "lucide-react";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { socialPostUrl } from "./socialUrls";

export function SocialPostMenu({ uri, className }: { uri: string; className: string }) {
  const [status, setStatus] = useState("");
  const url = socialPostUrl(uri);
  async function copyLink() {
    setStatus("");
    try {
      if (!url) return;
      await navigator.clipboard.writeText(url);
      setStatus("Post Link Copied");
    } catch {
      setStatus("Unable to copy the post link. Please try again.");
    }
  }
  return <>
    <DropdownMenu>
      <DropdownMenuTrigger className={className} aria-label="More Post Actions"><MoreHorizontal className="size-4" /></DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="min-w-40" onClick={event => event.stopPropagation()}>
        <DropdownMenuItem disabled={!url} render={<Link href={url ? `/social/messages?draft=${encodeURIComponent(url)}` : "/social/messages"} />}><Send className="size-4" />Send Message</DropdownMenuItem>
        <DropdownMenuItem disabled={!url} onClick={() => { void copyLink(); }}><Copy className="size-4" />Copy Link</DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
    {status ? <p role="status" className="col-span-2 max-w-32 text-right text-xs text-muted-foreground">{status}</p> : null}
  </>;
}
