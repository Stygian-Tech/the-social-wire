"use client";

import { useId } from "react";
import { ImagePlus, X } from "lucide-react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { MAX_USER_INPUT_PHOTOS } from "@/lib/userInputFeedback";

interface FeedbackPhotoPickerProps {
  disabled?: boolean;
  photos: File[];
  onPhotosChange: (photos: File[]) => void;
}

export function FeedbackPhotoPicker({
  disabled = false,
  photos,
  onPhotosChange,
}: FeedbackPhotoPickerProps) {
  const inputId = useId();
  const remaining = MAX_USER_INPUT_PHOTOS - photos.length;

  function addPhotos(files: FileList | null) {
    if (!files || remaining <= 0) return;
    const selected = Array.from(files)
      .filter((file) => file.type.startsWith("image/"))
      .slice(0, remaining);
    if (selected.length) onPhotosChange([...photos, ...selected]);
  }

  return (
    <fieldset className="space-y-2" disabled={disabled}>
      <legend className="text-sm font-medium">Photos</legend>
      <div className="flex flex-wrap items-center gap-2">
        <Input
          id={inputId}
          type="file"
          accept="image/*"
          multiple
          className="sr-only"
          disabled={disabled || remaining === 0}
          onChange={(event) => {
            const input = event.currentTarget;
            addPhotos(input.files);
            input.value = "";
          }}
        />
        <Label
          htmlFor={inputId}
          aria-disabled={disabled || remaining === 0}
          className="inline-flex h-8 cursor-pointer items-center gap-1 rounded-xl border border-border bg-card/90 px-3 text-[0.8rem] font-semibold shadow-sm transition-colors hover:bg-muted aria-disabled:pointer-events-none aria-disabled:opacity-50"
        >
          <ImagePlus className="size-3.5" aria-hidden />
          Add Photos
        </Label>
        <span className="text-xs text-muted-foreground">
          {photos.length} of {MAX_USER_INPUT_PHOTOS}
        </span>
      </div>
      {photos.length ? (
        <ul className="space-y-1" aria-label="Attached Photos">
          {photos.map((photo, index) => (
            <li
              key={`${photo.name}-${photo.size}-${photo.lastModified}-${index}`}
              className="flex min-w-0 items-center gap-2 rounded-xl border border-border/70 bg-muted/35 px-2 py-1.5 text-sm"
            >
              <ImagePlus className="size-4 shrink-0 text-muted-foreground" aria-hidden />
              <span className="min-w-0 flex-1 truncate">{photo.name}</span>
              <Button
                type="button"
                size="icon-xs"
                variant="ghost"
                aria-label={`Remove ${photo.name}`}
                onClick={() =>
                  onPhotosChange(photos.filter((_, itemIndex) => itemIndex !== index))
                }
              >
                <X />
              </Button>
            </li>
          ))}
        </ul>
      ) : (
        <p className="text-xs text-muted-foreground">
          Attach up to four images.
        </p>
      )}
    </fieldset>
  );
}
