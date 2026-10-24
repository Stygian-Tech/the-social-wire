"use client";

/* eslint-disable @next/next/no-img-element -- Private original image blobs retain their format. */
import { useEffect, useRef, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import type { BlockEditorHandle } from "@stygian/markdown-editor";
import { ChevronDown, Plus } from "lucide-react";
import { ArticleSchedulingNotSubmittedError } from "@/lib/articles/articleSchedulingError";
import { useSkejScheduling } from "@/hooks/useSkejScheduling";
import { useProEntitlements } from "@/hooks/useProEntitlements";
import { isSkejArticleSchedule } from "@/lib/skej/skejSchedulingClient";
import { ArticleScheduleDialog } from "./ArticleScheduleDialog";
import { ArticleScheduledList } from "./ArticleScheduledList";
import { useAuth } from "@/hooks/useAuth";
import { useArticleDrafts } from "@/hooks/articles/useArticleDrafts";
import { getArticleDraft, getArticleDraftAsset, saveArticleDraftAsset } from "@/lib/articles/articleDraftStorage";
import { articleDraftRecordKey, listArticlePublications, listPublishedArticles, publishArticle, uploadArticleImage } from "@/lib/articles/articlePublishingClient";
import type { ArticleImageAsset } from "@/lib/articles/articlePublishingTypes";
import { socialErrorMessage } from "@/lib/blueskySocialClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { SocialPermissionRecovery } from "@/components/Social/SocialPermissionRecovery";
import { floatingGlassClasses } from "@/components/shared/floatingChromeStyles";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import { ArticleImageInput, articleImageDimensions } from "./ArticleImageInput";
import { ArticleBodyViews, type ArticleBodyMode } from "./ArticleBodyViews";

export function ArticlesWorkspace() {
  const { session } = useAuth();
  return session ? <ArticlesViewer key={session.did} did={session.did} /> : <p className="p-6">Log In to Write Articles.</p>;
}

function ArticlesViewer({ did }: { did: string }) {
  const { getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const local = useArticleDrafts(did);
  const { isPro } = useProEntitlements();
  const scheduler = useSkejScheduling(did, did);
  const [scheduling, setScheduling] = useState(false);
  const actionLock = useRef(false);
  const mounted = useRef(true);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);
  const { draft } = local;
  const draftRef = useRef(draft);
  useEffect(() => { draftRef.current = draft; }, [draft]);
  const editor = useRef<BlockEditorHandle>(null);
  const cache = useQueryClient();
  const [tab, setTab] = useState<"drafts" | "scheduled" | "published">("drafts");
  const [mode, setMode] = useState<ArticleBodyMode>("editor");
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<string>();
  const [publishing, setPublishing] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [assetState, setAssetState] = useState<{ draftId?: string; urls: Record<string, string> }>({ urls: {} });
  const [publishedUrl, setPublishedUrl] = useState<string>();
  const session = () => { const value = getOAuthSession(); if (!value || value.did !== did) throw new Error("Log In Again to Continue."); return value; };
  const publications = useQuery({ queryKey: ["articles", did, "publications", oauthSessionReloadSeq], queryFn: ({ signal }) => listArticlePublications(session(), signal), retry: false });
  const history = useQuery({ queryKey: ["articles", did, "published", oauthSessionReloadSeq], queryFn: ({ signal }) => listPublishedArticles(session(), signal), retry: false });
  const publication = publications.data?.find(value => value.uri === draft?.publicationUri);
  const assets = draft?.assets ?? [];
  const draftId = draft?.id;
  const assetUrls = assetState.draftId === draftId ? assetState.urls : {};
  const assetKey = assets.map(asset => asset.id).join(",");
  useEffect(() => {
    let cancelled = false;
    const urls: Record<string, string> = {};
    void Promise.all(assetKey.split(",").filter(Boolean).map(async id => {
      if (!draftId) return;
      const blob = await getArticleDraftAsset(did, draftId, id);
      if (blob) urls[id] = URL.createObjectURL(blob);
    })).then(() => { if (!cancelled) setAssetState({ draftId, urls: { ...urls } }); else Object.values(urls).forEach(URL.revokeObjectURL); }).catch(error => { Object.values(urls).forEach(URL.revokeObjectURL); if (!cancelled) setFailure(error instanceof Error ? error.message : "Draft images could not be loaded."); });
    return () => { cancelled = true; Object.values(urls).forEach(URL.revokeObjectURL); };
  }, [did, draftId, assetKey]);
  const resolveImage = (url: string) => url.startsWith("article-asset://") ? assetUrls[url.slice("article-asset://".length)] : /^https:\/\//.test(url) ? url : undefined;
  async function perform(action: () => Promise<unknown>) {
    if (actionLock.current) return;
    actionLock.current = true;
    setBusy(true); setFailure(undefined);
    try { await action(); }
    catch (error) { setFailure(error instanceof Error ? socialErrorMessage(error) === SCOPE_RECOVERY_MESSAGE ? SCOPE_RECOVERY_MESSAGE : error.message : "This action could not be completed."); }
    finally { actionLock.current = false; setBusy(false); }
  }
  async function addImages(files: File[], insertionIndex?: number, cover = false) {
    await perform(async () => {
      const active = draftRef.current;
      if (!active || !files.length) return;
      await local.persist();
      const descriptors = [];
      for (const file of cover ? files.slice(0, 1) : files) {
        const dimensions = await articleImageDimensions(file);
        const id = crypto.randomUUID();
        await saveArticleDraftAsset(did, active.id, id, file);
        descriptors.push({ id, alt: "", ...dimensions, mimeType: file.type, name: file.name });
      }
      if (draftRef.current?.id !== active.id) return;
      local.update({ assets: [...draftRef.current.assets ?? [], ...descriptors], ...(cover ? { coverAssetId: descriptors[0]?.id } : {}) });
      if (!cover) {
        const markdown = descriptors.map(asset => `![](${"article-asset://" + asset.id})`).join("\n\n");
        if (mode === "editor") editor.current?.insertBlock(markdown, insertionIndex);
        else local.update({ markdown: `${draftRef.current.markdown}\n\n${markdown}`.trim() });
      }
      await local.persist();
    });
  }
  async function publish() {
    await perform(async () => {
      const active = draftRef.current;
      if (!active || !publication || active.publishedUri || active.scheduleRecordKey) return;
      await local.persist();
      const stored = await getArticleDraft(did, active.id);
      if (!stored || stored.scheduleRecordKey || stored.publishedUri) throw new Error("This Draft Changed in Another Tab. Reload It Before Publishing.");
      const images: ArticleImageAsset[] = [];
      for (const asset of active.assets ?? []) {
        if (asset.id !== active.coverAssetId && !active.markdown.includes(`article-asset://${asset.id}`)) continue;
        const file = await getArticleDraftAsset(did, active.id, asset.id);
        if (!file) throw new Error(`The private image “${asset.name}” is missing. Restore it before publishing.`);
        images.push({ ...await uploadArticleImage(session(), file, asset), id: asset.id });
      }
      const result = await publishArticle(session(), { recordKey: await articleDraftRecordKey(active.id, active.createdAt), publication, title: active.title, description: active.excerpt, path: active.path, tags: active.tags, markdown: active.markdown, bodyAssets: images.filter(image => image.id !== active.coverAssetId), cover: images.find(image => image.id === active.coverAssetId) });
      local.update({ publishedUri: result.uri });
      await local.persist();
      setPublishedUrl(result.url); setPublishing(false);
      await cache.invalidateQueries({ queryKey: ["articles", did, "published"] });
    });
  }
  async function schedule(instant: string) {
    if (actionLock.current) throw new Error("Another Article Action Is in Progress.");
    actionLock.current = true; setBusy(true);
    try {
      const active = draftRef.current;
      if (!active || !publication || active.publishedUri || active.scheduleRecordKey) throw new Error("This Draft Cannot Be Scheduled Again. Review Its Schedule First.");
      if (!isPro || !scheduler.readiness.data?.connected) throw new Error("Connect Skej With Social Wire Pro Before Scheduling.");
      if (active.coverAssetId || (active.assets ?? []).some(asset => active.markdown.includes(`article-asset://${asset.id}`)) || /!\[.*?\]\(/.test(active.markdown) || ["offprint", "pckt"].includes(publication.host)) throw new Error("Scheduling Supports Text Articles in Leaflet, Markpub, and Generic Publications. Remove Images Before Scheduling.");
      const snapshot = structuredClone(active);
      await local.persist();
      const stored = await getArticleDraft(did, snapshot.id);
      if (!stored || stored.scheduleRecordKey || stored.publishedUri) throw new Error("This Draft Changed in Another Tab. Reload It Before Scheduling.");
      const recordKey = await articleDraftRecordKey(snapshot.id, snapshot.createdAt);
      session();
      if (!mounted.current || draftRef.current?.id !== snapshot.id) throw new Error("Your Account or Draft Changed.");
      // Persist intent first. An ambiguous remote result must never enable a second publish.
      local.update({ scheduleRecordKey: recordKey, scheduleUri: undefined });
      await local.persist();
      session();
      if (!mounted.current) throw new Error("Your Account Changed.");
      try {
        const scheduled = await scheduler.scheduleArticle({ recordKey, publication, title: snapshot.title, description: snapshot.excerpt, path: snapshot.path, tags: snapshot.tags, markdown: snapshot.markdown }, instant);
        if (mounted.current && getOAuthSession()?.did === did && draftRef.current?.id === snapshot.id) {
          local.update({ scheduleUri: scheduled.scheduleUri }); await local.persist();
        }
      } catch (failure) {
        if (failure instanceof ArticleSchedulingNotSubmittedError && mounted.current && getOAuthSession()?.did === did && draftRef.current?.id === snapshot.id) {
          local.update({ scheduleRecordKey: undefined, scheduleUri: undefined }); await local.persist();
        }
        throw failure;
      }
      if (mounted.current) setTab("scheduled");
    } finally { actionLock.current = false; if (mounted.current) setBusy(false); }
  }
  const matchingSchedules = scheduler.schedules.data?.filter(item => isSkejArticleSchedule(item) && item.record.publishRkey === draft?.scheduleRecordKey);
  const confirmedCanceled = !!draft?.scheduleUri && !scheduler.schedules.isError
    && matchingSchedules?.some(item => item.scheduleUri === draft.scheduleUri && item.status === "canceled" && item.record.status === "canceled")
    && matchingSchedules.every(item => item.status === "canceled" && item.record.status === "canceled");
  const error = failure ?? local.error ?? (publications.error ? socialErrorMessage(publications.error) : undefined);
  return <div className="flex min-h-0 min-w-0 flex-1 flex-col">
    <FeedHeader title="Articles" subtitle="Write and Publish"><Button size="sm" disabled={busy || local.loading} onClick={() => { void perform(async () => { await local.create(publications.data?.[0]?.uri); setTab("drafts"); setPublishedUrl(undefined); }); }}><Plus className="size-4" />New Article</Button></FeedHeader>
    {error ? <div role="alert" className="border-b p-3 text-sm text-destructive">{error}{error === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : <Button variant="outline" size="sm" className="ml-2" onClick={() => { void perform(async () => { await local.persist(); await publications.refetch(); }); }}>Retry</Button>}</div> : null}
    <div className="flex min-h-0 flex-1 flex-col overflow-y-auto md:flex-row md:overflow-hidden">
      <aside aria-label="Article Library" className={`${floatingGlassClasses} m-4 min-h-0 shrink-0 p-3 md:w-72 md:overflow-y-auto`}>
        <div aria-label="Article Sections" className="mb-3 flex"><Button variant={tab === "drafts" ? "secondary" : "ghost"} size="sm" aria-pressed={tab === "drafts"} onClick={() => setTab("drafts")}>Drafts</Button><Button variant={tab === "scheduled" ? "secondary" : "ghost"} size="sm" aria-pressed={tab === "scheduled"} onClick={() => setTab("scheduled")}>Scheduled</Button><Button variant={tab === "published" ? "secondary" : "ghost"} size="sm" aria-pressed={tab === "published"} onClick={() => setTab("published")}>Published</Button></div>
        {tab === "scheduled" ? <ArticleScheduledList scheduler={scheduler} isPro={isPro} onCanceled={async item => {
          if (isSkejArticleSchedule(item) && draftRef.current?.scheduleRecordKey === item.record.publishRkey && draftRef.current?.scheduleUri === item.scheduleUri) { local.update({ scheduleRecordKey: undefined, scheduleUri: undefined }); await local.persist(); }
        }} /> : local.loading ? <p role="status" className="text-sm">Loading Drafts…</p> : tab === "drafts" ? <><p className="mb-3 text-xs text-muted-foreground">Private Drafts · This Browser Only</p><nav aria-label="Article Drafts" className="flex flex-col gap-1">{local.drafts.map(row => <Button key={row.id} variant={row.id === draft?.id ? "secondary" : "ghost"} className="h-auto justify-start whitespace-normal py-2 text-left" disabled={busy} onClick={() => { void perform(async () => { await local.select(row.id); setPublishedUrl(undefined); }); }}><span className="min-w-0 break-words">{row.title || "Untitled Article"}{row.publishedUri ? <span className="block text-xs text-muted-foreground">Published</span> : null}</span></Button>)}</nav>{!local.drafts.length ? <p className="text-sm text-muted-foreground">Create an article to start writing.</p> : null}</> : <>{history.isPending ? <p role="status">Loading Published Articles…</p> : history.error ? <p role="alert" className="text-sm">{socialErrorMessage(history.error)}</p> : !history.data?.length ? <p className="text-sm text-muted-foreground">No Published Articles Yet.</p> : history.data.map(row => <div key={row.uri} className="mb-2 rounded-lg border p-2"><p className="break-words text-sm font-medium">{String(row.record.title ?? "Untitled Article")}</p><p className="mt-1 break-all text-xs text-muted-foreground">{row.uri}</p></div>)}</>}
      </aside>
      {!draft ? <div className="flex min-h-60 flex-1 items-center justify-center p-6 text-muted-foreground">Select a Draft or Create an Article.</div> : <div className="flex min-w-0 shrink-0 flex-col md:min-h-0 md:flex-1 lg:flex-row">
        <section aria-label="Article Editor" aria-busy={busy} className="min-w-0 shrink-0 p-4 sm:p-6 md:min-h-0 md:flex-1 md:overflow-y-auto">
          <div className="mb-4 flex flex-wrap items-center gap-2"><p role="status" className="mr-auto text-xs text-muted-foreground">{local.status}</p><Button variant="outline" size="sm" disabled={busy} onClick={() => { void perform(local.persist); }}>Save Draft</Button><Button size="sm" disabled={busy || !publication || !draft.title.trim() || !draft.markdown.trim() || !!draft.publishedUri || !!draft.scheduleRecordKey} onClick={() => setPublishing(true)}>Publish Article</Button><Button size="sm" variant="outline" disabled={busy || !isPro || !scheduler.readiness.data?.connected || !publication || !draft.title.trim() || !draft.markdown.trim() || !!draft.publishedUri || !!draft.scheduleRecordKey} onClick={() => setScheduling(true)}>Schedule Article</Button></div>
          {!isPro ? <p className="mb-3 text-xs text-muted-foreground">Article Scheduling Requires Social Wire Pro.</p> : !scheduler.readiness.data?.connected ? <p className="mb-3 text-xs text-muted-foreground">Open Scheduled to Connect Skej.</p> : null}
          {draft.scheduleRecordKey ? <p role="status" className="mb-4 rounded-lg bg-muted p-3 text-sm">Scheduling Was Requested. This Draft Is Locked to Prevent Duplicate Publication. Review or Cancel Its Schedule in Scheduled. If the Request Failed, Refresh Schedules Before Taking Further Action.</p> : null}
          {draft.scheduleRecordKey && confirmedCanceled ? <Button variant="outline" size="sm" disabled={busy} onClick={() => { void perform(async () => { local.update({ scheduleRecordKey: undefined, scheduleUri: undefined }); await local.persist(); }); }}>Unlock Canceled Draft</Button> : null}
          {draft.publishedUri ? <p className="mb-4 rounded-lg bg-muted p-3 text-sm">Published to Your PDS. {publishedUrl ? <a href={publishedUrl} target="_blank" rel="noopener noreferrer" className="text-primary hover:underline">Open Article</a> : null} Published article editing will be available in a later phase.</p> : null}
          {mode === "viewer" ? <header className="mb-5 space-y-2"><h1 className="break-words text-3xl font-semibold leading-tight">{draft.title || "Untitled Article"}</h1>{draft.excerpt ? <p className="whitespace-pre-wrap text-muted-foreground">{draft.excerpt}</p> : null}</header> : <label className="mb-5 block"><span className="mb-2 block text-sm font-medium">Title</span><Input aria-label="Article Title" placeholder="Untitled Article" value={draft.title} disabled={busy || !!draft.publishedUri || !!draft.scheduleRecordKey} onChange={event => local.update({ title: event.target.value })} className="h-auto py-2 text-xl font-semibold" /></label>}
          {draft.coverAssetId && assetUrls[draft.coverAssetId] ? <img src={assetUrls[draft.coverAssetId]} alt={assets.find(asset => asset.id === draft.coverAssetId)?.alt ?? ""} className="mb-5 max-h-72 w-full rounded-xl object-cover" /> : null}
          <ArticleBodyViews draftId={draft.id} markdown={draft.markdown} mode={mode} onModeChange={setMode} onChange={markdown => local.update({ markdown })} editorRef={editor} resolveImageURL={resolveImage} onImageFiles={(files, index) => addImages(files, index)} readOnly={busy || !!draft.publishedUri || !!draft.scheduleRecordKey} busy={busy} controls={<ArticleImageInput label="Add Images" multiple disabled={busy || !!draft.publishedUri || !!draft.scheduleRecordKey} onFiles={files => addImages(files)} />} />
        </section>
        <aside aria-label="Article Details" className={`${floatingGlassClasses} m-4 min-h-0 shrink-0 space-y-4 p-4 md:overflow-y-auto lg:w-64`}>
          <h2 className="text-sm font-semibold">Article Details</h2>
          <label className="block space-y-1 text-sm"><span>Publication</span><div className="relative"><select aria-label="Article Publication" value={draft.publicationUri} disabled={busy || !!draft.publishedUri || !!draft.scheduleRecordKey} onChange={event => local.update({ publicationUri: event.target.value })} className="w-full appearance-none rounded-md border bg-background py-2 pl-3 pr-9"><option value="">Select a Publication</option>{publications.data?.map(pub => <option key={pub.uri} value={pub.uri}>{pub.name}</option>)}</select><ChevronDown className="pointer-events-none absolute top-1/2 right-3 size-4 -translate-y-1/2" aria-hidden="true" /></div></label>
          {publications.isPending ? <p role="status" className="text-xs">Loading Publications…</p> : !publications.error && !publications.data?.length ? <p className="text-xs text-muted-foreground">Create a publication in your publishing app, then refresh here.</p> : null}
          <Button size="sm" variant="outline" disabled={busy || publications.isFetching} onClick={() => { void publications.refetch(); }}>Refresh Publications</Button>
          {publication?.host === "unknown" || publication?.host === "pckt" ? <p className="text-xs text-muted-foreground">{publication.host === "pckt" ? "Published records will be stored on your PDS; pckt does not currently display externally published articles." : "This publication uses a generic format. Its website may not support all formatting."}</p> : null}
          <label className="block space-y-1 text-sm"><span>Excerpt</span><textarea aria-label="Article Excerpt" value={draft.excerpt} disabled={busy || !!draft.publishedUri || !!draft.scheduleRecordKey} onChange={event => local.update({ excerpt: event.target.value })} rows={3} className="w-full rounded-md border bg-background p-2 text-sm" /></label>
          <label className="block space-y-1 text-sm"><span>Path</span><Input aria-label="Article Path" placeholder="/my-article" value={draft.path} disabled={busy || !!draft.publishedUri || !!draft.scheduleRecordKey} onChange={event => local.update({ path: event.target.value })} /></label>
          <label className="block space-y-1 text-sm"><span>Tags</span><Input aria-label="Article Tags" placeholder="Comma-Separated Tags" value={draft.tags.join(", ")} disabled={busy || !!draft.publishedUri || !!draft.scheduleRecordKey} onChange={event => local.update({ tags: event.target.value.split(",").map(tag => tag.trimStart()) })} /></label>
          <ArticleImageInput label="Choose Cover Image" disabled={busy || !!draft.publishedUri || !!draft.scheduleRecordKey} onFiles={files => addImages(files, undefined, true)} />
          {draft.coverAssetId ? <Button variant="ghost" size="sm" disabled={busy || !!draft.publishedUri || !!draft.scheduleRecordKey} onClick={() => local.update({ coverAssetId: undefined })}>Remove Cover</Button> : null}
          {assets.map(asset => <label key={asset.id} className="block space-y-1 text-xs"><span className="block truncate">{asset.name} · Image Description</span><Input aria-label={`Image Description: ${asset.name}`} value={asset.alt} disabled={busy || !!draft.publishedUri || !!draft.scheduleRecordKey} onChange={event => local.update({ assets: assets.map(value => value.id === asset.id ? { ...value, alt: event.target.value } : value) })} /></label>)}
          <Button variant="destructive" size="sm" disabled={busy || !!draft.scheduleRecordKey} onClick={() => setDeleting(true)}>Delete Local Draft</Button>
        </aside>
      </div>}
    </div>
    {scheduling && draft ? <ArticleScheduleDialog title={draft.title} save={schedule} close={() => setScheduling(false)} /> : null}
    <Dialog open={publishing} onOpenChange={open => { if (!busy) setPublishing(open); }}><DialogContent><DialogTitle>Publish Article?</DialogTitle><DialogDescription>This publishes “{draft?.title}” to {publication?.name} on your public PDS.</DialogDescription>{failure ? <p role="alert" className="text-sm text-destructive">{failure}</p> : null}<div className="flex gap-2"><Button disabled={busy} onClick={() => { void publish(); }}>{busy ? "Publishing…" : "Publish Now"}</Button><DialogClose render={<Button variant="outline" disabled={busy} />}>Cancel</DialogClose></div></DialogContent></Dialog>
    <Dialog open={deleting} onOpenChange={open => { if (!busy) setDeleting(open); }}><DialogContent><DialogTitle>Delete Local Draft?</DialogTitle><DialogDescription>This removes the private draft and its images from this browser. Published PDS records remain available.</DialogDescription><div className="flex gap-2"><Button variant="destructive" disabled={busy} onClick={() => { if (draft) void perform(async () => { await local.remove(draft.id); setDeleting(false); }); }}>Delete Draft</Button><DialogClose render={<Button variant="outline" disabled={busy} />}>Cancel</DialogClose></div></DialogContent></Dialog>
  </div>;
}
