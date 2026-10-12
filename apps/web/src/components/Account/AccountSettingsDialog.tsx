"use client";

import { Settings } from "lucide-react";
import { useEffect, useState } from "react";
import { useAuth } from "@/hooks/useAuth";
import { Button } from "@/components/ui/button";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { AccountSettingsContent } from "./AccountSettingsContent";

export function AccountSettingsDialog() {
  const { session } = useAuth();
  const [open, setOpen] = useState(false);

  useEffect(() => {
    const openFromHash = () => {
      if (["#settings", "#read-history", "#opml-import"].includes(window.location.hash)) setOpen(true);
    };
    queueMicrotask(openFromHash);
    window.addEventListener("hashchange", openFromHash);
    return () => window.removeEventListener("hashchange", openFromHash);
  }, []);

  useEffect(() => {
    if (!open) return;
    const frame = requestAnimationFrame(() => {
      const id = window.location.hash.slice(1);
      if (["settings", "read-history", "opml-import"].includes(id)) document.getElementById(id)?.scrollIntoView?.({ block: "start" });
    });
    return () => cancelAnimationFrame(frame);
  }, [open]);

  return <Dialog open={open} onOpenChange={(nextOpen) => {
    setOpen(nextOpen);
    if (!nextOpen && ["#settings", "#read-history", "#opml-import"].includes(window.location.hash)) {
      window.history.replaceState(window.history.state, "", `${window.location.pathname}${window.location.search}`);
    }
  }}>
    <DialogTrigger render={<Button variant="ghost" size="icon" className="min-h-11 min-w-11 sm:min-h-0 sm:min-w-0" />} aria-label="Settings" title="Settings">
      <Settings aria-hidden="true" />
    </DialogTrigger>
    <DialogContent showCloseButton={false} className="flex max-h-[min(90svh,56rem)] flex-col gap-0 overflow-hidden p-0 sm:max-w-2xl">
      <DialogHeader className="shrink-0 flex-row items-center justify-between border-b p-4">
        <div className="flex flex-col gap-1">
          <DialogTitle>Settings</DialogTitle>
          <DialogDescription>Manage your account and app preferences.</DialogDescription>
        </div>
        <DialogClose render={<Button variant="ghost" />}>Done</DialogClose>
      </DialogHeader>
      <div className="min-h-0 overflow-y-auto overscroll-contain"><AccountSettingsContent key={session?.did ?? "signed-out"} /></div>
    </DialogContent>
  </Dialog>;
}
