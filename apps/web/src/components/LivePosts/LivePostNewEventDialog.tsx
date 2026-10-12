"use client";

import { useState } from "react";
import { ChevronDown } from "lucide-react";
import type { ArticlePublication } from "@/lib/articles/articlePublishingTypes";
import type { CreateLiveEventInput } from "@/lib/livePosts/livePostTypes";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";

export type LivePostNewEventInput = CreateLiveEventInput;

type Props = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  publications: ArticlePublication[];
  publicationsLoading: boolean;
  pending: boolean;
  onCreate: (input: LivePostNewEventInput) => Promise<void>;
  initialEvent?: Partial<LivePostNewEventInput>;
};

export function LivePostNewEventDialog({ open, onOpenChange, publications, publicationsLoading, pending, onCreate, initialEvent }: Props) {
  const [title, setTitle] = useState(initialEvent?.title ?? "");
  const [tags, setTags] = useState(initialEvent?.tags?.join(", ") ?? "");
  const [destination, setDestination] = useState<LivePostNewEventInput["destination"]>("bluesky");
  const [publicationUri, setPublicationUri] = useState("");
  const [error, setError] = useState<string>();
  const blog = destination !== "bluesky";
  const eligiblePublication = publications.find(publication => publication.uri === publicationUri);
  const tagsValue = [...new Set(tags.split(",").map(tag => tag.trim().replace(/^#+/, "")).filter(Boolean))];
  async function create() {
    setError(undefined);
    try { await onCreate({ ...initialEvent, title: title.trim(), tags: tagsValue, destination, publicationUri: blog ? eligiblePublication?.uri : undefined }); }
    catch (failure) { setError(failure instanceof Error ? failure.message : "The event could not be created."); }
  }
  function changeOpen(next: boolean) {
    if (pending) return;
    if (next) { setTitle(initialEvent?.title ?? ""); setTags(initialEvent?.tags?.join(", ") ?? ""); setDestination("bluesky"); setPublicationUri(""); setError(undefined); }
    onOpenChange(next);
  }
  return <Dialog open={open} onOpenChange={changeOpen}><DialogContent className="sm:max-w-lg">
    <DialogTitle>New Live Event</DialogTitle>
    <DialogDescription>Choose where updates are published. The event title and tags apply to every update. Blog updates create a new article and append timestamped entries.</DialogDescription>
    <form className="flex flex-col gap-4" onSubmit={event => { event.preventDefault(); void create(); }}>
      <label className="space-y-1 text-sm"><span>Event Title</span><Input autoFocus aria-label="Event Title" value={title} onChange={event => setTitle(event.target.value)} disabled={pending} required maxLength={200} /></label>
      <label className="space-y-1 text-sm"><span>Hashtags</span><Input aria-label="Event Hashtags" placeholder="Comma-Separated Hashtags" value={tags} onChange={event => setTags(event.target.value)} disabled={pending} /></label>
      {initialEvent?.startsAt || initialEvent?.endsAt ? <div aria-label="Event Schedule" className="space-y-1 text-xs text-muted-foreground">{initialEvent.startsAt ? <p>Starts <time dateTime={initialEvent.startsAt}>{new Date(initialEvent.startsAt).toLocaleString()}</time></p> : null}{initialEvent.endsAt ? <p>Ends <time dateTime={initialEvent.endsAt}>{new Date(initialEvent.endsAt).toLocaleString()}</time></p> : null}</div> : null}
      <fieldset disabled={pending} className="space-y-2"><legend className="mb-2 text-sm font-medium">Publish To</legend><div className="flex flex-wrap gap-3">{([['bluesky', 'Bluesky'], ['blog', 'Blog'], ['both', 'Both']] as const).map(([value, label]) => <label key={value} className="flex items-center gap-2 text-sm"><input type="radio" name="live-post-destination" value={value} checked={destination === value} onChange={() => setDestination(value)} disabled={value !== 'bluesky' && (!publications.length || publicationsLoading)} />{label}</label>)}</div></fieldset>
      {publicationsLoading ? <p role="status" className="text-xs text-muted-foreground">Loading Publications…</p> : !publications.length ? <p className="text-xs text-muted-foreground">Blog publishing needs a standard.site publication owned by your account.</p> : null}
      {blog ? <label className="space-y-1 text-sm"><span>Publication</span><div className="relative"><select aria-label="Event Publication" value={publicationUri} onChange={event => setPublicationUri(event.target.value)} disabled={pending} className="w-full appearance-none rounded-md border bg-background py-2 pl-3 pr-9"><option value="">Select a Publication</option>{publications.map(publication => <option key={publication.uri} value={publication.uri}>{publication.name}</option>)}</select><ChevronDown aria-hidden="true" className="pointer-events-none absolute right-3 top-1/2 size-4 -translate-y-1/2" /></div></label> : null}
      {error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}
      <div className="flex justify-end gap-2"><DialogClose render={<Button type="button" variant="outline" disabled={pending} />}>Cancel</DialogClose><Button type="submit" disabled={pending || !title.trim() || (blog && !eligiblePublication)}>{pending ? "Creating…" : "Create Event"}</Button></div>
    </form>
  </DialogContent></Dialog>;
}
