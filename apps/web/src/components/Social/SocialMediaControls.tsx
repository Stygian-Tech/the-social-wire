"use client";

import { useRef, useState } from "react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { prepareComposerPhoto } from "@/lib/prepareComposerPhoto";
import type { ComposerMedia, ComposerPhoto, GifAsset } from "@/lib/composerMedia";
import { Button } from "@/components/ui/button";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import { SocialGifPicker } from "./SocialGifPicker";
import { SocialGifPlayer } from "./SocialGifPlayer";
import { SocialPhotoPreview } from "./SocialPhotoPreview";

type Update = (change: (previous?: ComposerMedia) => ComposerMedia | undefined) => void;
export function SocialMediaControls({ media, update, session, disabled, hasLink, removeLink, registerIntake }: { media?: ComposerMedia; update: Update; session?: OAuthSession | null; disabled: boolean; hasLink: boolean; removeLink: () => void; registerIntake?: React.RefObject<((files: File[]) => void) | undefined> }) {
  const files = useRef<HTMLInputElement>(null);
  const [picker, setPicker] = useState(false);
  const [error, setError] = useState<string>();
  const [altID, setAltID] = useState<string>();
  const [alt, setAlt] = useState("");
  const [replace, setReplace] = useState<(() => void) | undefined>();
  const updateRef = useRef(update);
  updateRef.current = update;
  function replacing(action: () => void, conflict: boolean) { if (conflict || hasLink) setReplace(() => action); else action(); }
  async function prepare(photo: ComposerPhoto) {
    try {
      const ready = await prepareComposerPhoto(photo);
      updateRef.current(previous => previous?.kind === "photos" ? { ...previous, photos: previous.photos.map(item => item.id === photo.id ? { ...ready, alt: item.alt } : item) } : previous);
    } catch (cause) {
      updateRef.current(previous => previous?.kind === "photos" ? { ...previous, photos: previous.photos.map(item => item.id === photo.id ? { ...item, status: "failed", error: cause instanceof Error ? cause.message : "Photo Could Not Be Prepared" } : item) } : previous);
    }
  }
  function intake(selected: File[]) {
    if (disabled || !selected.length) return;
    replacing(() => {
      setError(undefined);
      const available = 4 - (media?.kind === "photos" ? media.photos.length : 0);
      if (selected.length > available) setError(`Only ${available} More Photos Can Be Added To This Post`);
      const added = selected.slice(0, available).map(original => ({ id: crypto.randomUUID(), name: original.name, original, alt: "", status: "preparing" as const }));
      update(previous => ({ kind: "photos", photos: [...(previous?.kind === "photos" ? previous.photos : []), ...added].slice(0, 4) }));
      added.forEach(photo => void prepare(photo));
    }, media?.kind === "gif");
  }
  if (registerIntake) registerIntake.current = intake;
  function selectGif(asset: GifAsset) {
    replacing(() => { update(() => ({ kind: "gif", asset, alt: "" })); setPicker(false); }, media?.kind === "photos");
  }
  function editAlt(id: string) { setAltID(id); setAlt(media?.kind === "gif" ? media.alt : media?.photos.find(photo => photo.id === id)?.alt ?? ""); }
  return <div className="flex min-w-0 flex-col gap-3">
    <div className="flex flex-wrap gap-2"><Button type="button" variant="outline" size="sm" disabled={disabled || (media?.kind === "photos" && media.photos.length === 4)} onClick={() => files.current?.click()}>Add Photos</Button><Button type="button" variant="outline" size="sm" disabled={disabled || !session} onClick={() => setPicker(true)}>GIF</Button></div>
    <input ref={files} type="file" accept="image/jpeg,image/png" multiple hidden aria-label="Choose Photos" disabled={disabled} onChange={event => { intake(Array.from(event.target.files ?? [])); event.target.value = ""; }} />
    {error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}
    {media?.kind === "photos" ? <div className="grid min-w-0 grid-cols-2 gap-3">{media.photos.map((photo, index) => <div key={photo.id} className="min-w-0 rounded-xl border p-2">
      <SocialPhotoPreview photo={photo} /><p className="truncate text-xs">{photo.name}</p>
      {photo.status === "preparing" ? <p role="status" className="text-xs">Preparing Photo…</p> : null}
      {photo.error ? <p role="alert" className="text-xs text-destructive">{photo.error}</p> : null}
      <div className="mt-2 flex flex-wrap gap-1"><Button type="button" size="sm" variant="outline" disabled={disabled} onClick={() => editAlt(photo.id)}>{photo.alt ? "Edit Alt Text" : "Add Alt Text"}</Button>
        {photo.status === "failed" ? <Button type="button" size="sm" variant="outline" disabled={disabled} onClick={() => { update(previous => previous?.kind === "photos" ? { ...previous, photos: previous.photos.map(item => item.id === photo.id ? { ...item, status: "preparing", error: undefined } : item) } : previous); void prepare(photo); }}>Retry</Button> : null}
        <Button type="button" size="sm" variant="ghost" disabled={disabled} aria-label={`Remove Photo ${index + 1}`} onClick={() => update(previous => previous?.kind === "photos" ? previous.photos.length === 1 ? undefined : { ...previous, photos: previous.photos.filter(item => item.id !== photo.id) } : previous)}>Remove</Button>
        {([-1, 1] as const).map(direction => <Button type="button" key={direction} size="sm" variant="ghost" aria-label={`Move Photo ${index + 1} ${direction < 0 ? "Left" : "Right"}`} disabled={disabled || index + direction < 0 || index + direction >= media.photos.length} onClick={() => update(previous => { if (previous?.kind !== "photos") return previous; const next = [...previous.photos]; [next[index], next[index + direction]] = [next[index + direction], next[index]]; return { ...previous, photos: next }; })}>{direction < 0 ? "←" : "→"}</Button>)}
      </div>
    </div>)}</div> : null}
    {media?.kind === "gif" ? <div className="flex flex-col gap-2 rounded-xl border p-3"><SocialGifPlayer key={media.asset.id} source={media.asset.url} poster={media.asset.poster} mp4={media.asset.mp4} webm={media.asset.webm} alt={media.alt || media.asset.description || media.asset.title} width={media.asset.width} height={media.asset.height} /><p className="text-xs text-muted-foreground">{media.asset.attribution}</p><div className="flex flex-wrap gap-2"><Button type="button" variant="outline" size="sm" disabled={disabled} onClick={() => editAlt("gif")}>{media.alt ? "Edit Alt Text" : "Add Alt Text"}</Button><Button type="button" variant="outline" size="sm" disabled={disabled} onClick={() => setPicker(true)}>Replace GIF</Button><Button type="button" variant="ghost" size="sm" disabled={disabled} onClick={() => update(() => undefined)}>Remove GIF</Button></div></div> : null}
    {picker && session ? <SocialGifPicker session={session} onClose={() => setPicker(false)} onSelect={selectGif} /> : null}
    {replace ? <Dialog open onOpenChange={open => { if (!open) setReplace(undefined); }}><DialogContent onKeyDown={event => event.stopPropagation()}><DialogTitle>Replace Current Attachment?</DialogTitle><DialogDescription>Each Post Supports Photos, One GIF, Or A Link Preview. Your Text Will Be Kept.</DialogDescription><Button type="button" onClick={() => { removeLink(); replace(); setReplace(undefined); }}>Replace Attachment</Button><DialogClose>Keep Current Attachment</DialogClose></DialogContent></Dialog> : null}
    {altID ? <Dialog open onOpenChange={open => { if (!open) setAltID(undefined); }}><DialogContent onKeyDown={event => event.stopPropagation()}><DialogTitle>Describe This {media?.kind === "gif" ? "GIF" : "Photo"}</DialogTitle><DialogDescription>Describe The Meaningful Content For People Who Cannot See It.</DialogDescription><label className="flex flex-col gap-2 text-sm">Alt Text<textarea autoFocus rows={5} maxLength={2000} value={alt} onChange={event => setAlt(event.target.value)} className="rounded-xl border bg-background p-3" /></label><p className="text-xs">{alt.length}/2000</p><Button type="button" onClick={() => { update(previous => previous?.kind === "gif" ? { ...previous, alt } : previous?.kind === "photos" ? { ...previous, photos: previous.photos.map(photo => photo.id === altID ? { ...photo, alt } : photo) } : previous); setAltID(undefined); }}>Save Description</Button><DialogClose>Cancel</DialogClose></DialogContent></Dialog> : null}
  </div>;
}
