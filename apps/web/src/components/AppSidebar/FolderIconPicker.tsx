"use client";

import { useId, useState } from "react";
import { Input } from "@/components/ui/input";
import { folderEmojiOptions, isFolderEmoji } from "./folderEmoji";
import { cn } from "@/lib/utils";
import { folderIconOptions } from "./FolderIcon";

export function FolderIconPicker({
  labelledBy,
  value,
  onChange,
  disabled = false,
}: {
  labelledBy: string;
  value: string;
  onChange: (value: string) => void;
  disabled?: boolean;
}) {
  const emojiId = useId();
  const [customEmoji, setCustomEmoji] = useState(isFolderEmoji(value) ? value.trim() : "");
  const trimmed = value.trim();
  const selected = isFolderEmoji(trimmed) || folderIconOptions.some(
    (option) => option.value === trimmed
  )
    ? trimmed
    : "folder";
  const selectedClass =
    "border-[var(--purple-border-strong)] bg-[var(--purple-surface)] text-[var(--purple-foreground)] [box-shadow:var(--purple-sidebar-selected)] hover:bg-[var(--purple-surface)] hover:text-[var(--purple-foreground)]";

  return (
    <div className="space-y-3">
    <div
      role="radiogroup"
      aria-labelledby={labelledBy}
      className="grid max-h-[7.75rem] grid-cols-5 gap-1.5 overflow-y-auto overscroll-contain pr-1"
    >
      {folderIconOptions.map((option) => (
        <button
          key={option.value}
          type="button"
          role="radio"
          aria-checked={selected === option.value}
          title={option.label}
          disabled={disabled}
          onClick={() => onChange(option.value)}
          className={cn(
            "flex h-9 items-center justify-center rounded-lg border border-border/70 bg-background/35 text-muted-foreground transition hover:bg-accent hover:text-accent-foreground",
            selected === option.value && selectedClass
          )}
        >
          <option.Icon className="h-4 w-4" aria-hidden />
          <span className="sr-only">{option.label}</span>
        </button>
      ))}
    </div>
    <fieldset disabled={disabled} className="space-y-2">
      <legend className="mb-2 text-sm font-medium">Emoji</legend>
      <div role="radiogroup" aria-label="Folder Emoji" className="grid grid-cols-5 gap-1.5">
        {folderEmojiOptions.map(option => <button key={option.value} type="button" role="radio" aria-checked={trimmed === option.value} aria-label={`${option.label} Emoji`} title={option.label} onClick={() => { setCustomEmoji(option.value); onChange(option.value); }} className={cn("flex h-9 items-center justify-center rounded-lg border border-border/70 bg-background/35 text-lg transition hover:bg-accent", trimmed === option.value && selectedClass)}><span aria-hidden>{option.value}</span></button>)}
      </div>
      <label htmlFor={emojiId} className="block text-xs text-muted-foreground">Custom Emoji</label>
      <Input id={emojiId} aria-describedby={`${emojiId}-hint`} value={customEmoji} placeholder="Paste an Emoji" onChange={event => { const next = event.target.value; setCustomEmoji(next); if (isFolderEmoji(next)) onChange(next.trim()); }} />
      <p id={`${emojiId}-hint`} className="text-xs text-muted-foreground">Choose or paste a single emoji.</p>
      {customEmoji && !isFolderEmoji(customEmoji) ? <p role="status" className="text-xs text-destructive">Enter One Emoji to Select It.</p> : null}
    </fieldset>
    </div>
  );
}
