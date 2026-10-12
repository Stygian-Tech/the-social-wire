"use client";

import { useLayoutEffect, useRef } from "react";
import { ArrowUp } from "lucide-react";
import { floatingGlassClasses } from "@/components/shared/floatingChromeStyles";
import { cn } from "@/lib/utils";
import { SocialPeopleTextField } from "./SocialPeopleTextField";

export function SocialMessageInput({ id, label, text, onChange, pending, valid, onSend }: { id: string; label: string; text: string; onChange: (text: string) => void; pending: boolean; valid: boolean; onSend: () => void }) {
  const input = useRef<HTMLTextAreaElement>(null);
  useLayoutEffect(() => {
    const element = input.current;
    if (!element) return;
    element.style.height = "0px";
    element.style.height = `${Math.min(160, Math.max(36, element.scrollHeight))}px`;
  }, [text]);
  return <div className={cn(floatingGlassClasses, "flex items-end gap-1 rounded-3xl px-2 py-1 focus-within:ring-2 focus-within:ring-ring")}>
    <label htmlFor={id} className="sr-only">{label}</label>
    <SocialPeopleTextField ref={input} id={id} disabled={pending} value={text} onValueChange={onChange} rows={1} placeholder="Message…" onKeyDown={event => {
      if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing && event.keyCode !== 229) {
        event.preventDefault();
        if (valid && !pending) onSend();
      }
    }} className="block max-h-40 min-h-9 min-w-0 w-full flex-1 resize-none overflow-y-auto bg-transparent px-2 py-2 text-sm leading-5 outline-none" />
    <button type="submit" aria-label="Send Message" title="Send Message" disabled={pending || !valid} className="flex min-h-9 min-w-9 shrink-0 items-center justify-center rounded-full bg-primary text-primary-foreground hover:opacity-90 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring disabled:opacity-40"><ArrowUp aria-hidden="true" className="size-4" /></button>
  </div>;
}
