"use client";

import { useId, useMemo, type ReactNode, type RefObject } from "react";
import { BlockDocumentRenderer, MarkdownBlockEditor, importMarkdownDocument, type BlockEditorHandle } from "@stygian/markdown-editor";
import { Button } from "@/components/ui/button";

export type ArticleBodyMode = "editor" | "markdown" | "viewer";

export function ArticleBodyViews({ draftId, markdown, mode, onModeChange, onChange, editorRef, resolveImageURL, onImageFiles, readOnly, busy = false, controls }: {
  draftId: string;
  markdown: string;
  mode: ArticleBodyMode;
  onModeChange: (mode: ArticleBodyMode) => void;
  onChange: (markdown: string) => void;
  editorRef: RefObject<BlockEditorHandle | null>;
  resolveImageURL: (url: string) => string | undefined;
  onImageFiles: (files: File[], index?: number) => Promise<void>;
  readOnly: boolean;
  busy?: boolean;
  controls?: ReactNode;
}) {
  const id = useId();
  const document = useMemo(() => mode === "viewer" ? importMarkdownDocument(markdown) : undefined, [markdown, mode]);
  return <>
    <div className="mb-4 flex flex-wrap items-center gap-2" role="group" aria-label="Article View">
      {(["editor", "markdown", "viewer"] as const).map(value => <Button key={value} type="button" disabled={busy} variant={mode === value ? "secondary" : "ghost"} size="sm" aria-pressed={mode === value} aria-controls={id} onClick={() => onModeChange(value)}>{value === "editor" ? "Editor" : value === "markdown" ? "Markdown" : "Article Viewer"}</Button>)}
      {controls}
    </div>
    <div id={id} className="article-body typeset-block-editor min-w-0">
      {mode === "editor" ? <div className={readOnly ? "pointer-events-none opacity-80" : undefined} inert={readOnly || undefined}>
        <MarkdownBlockEditor key={draftId} ref={editorRef} value={markdown} onChange={onChange} resolveImageURL={resolveImageURL} onImageFiles={onImageFiles} />
      </div> : mode === "markdown" ? <textarea aria-label="Article Markdown" value={markdown} onChange={event => onChange(event.target.value)} disabled={readOnly} spellCheck={false} className="min-h-80 w-full resize-y rounded-lg border bg-background p-3 font-mono text-sm leading-relaxed [tab-size:2]" /> : <article aria-label="Article Viewer" className="article-content min-w-0 py-2"><BlockDocumentRenderer document={document!} resolveImageURL={resolveImageURL} /></article>}
    </div>
  </>;
}
