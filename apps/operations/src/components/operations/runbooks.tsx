import type { Runbook } from "@/components/operations/shell/operations-view-types"

export function Runbooks({ runbooks }: { runbooks: Runbook[] }) {
  return (
    <section className="ops-panel divide-y divide-border/45">
      {runbooks.map((runbook, index) => (
        <article id={runbook.slug} key={runbook.slug} className="grid scroll-mt-36 gap-3 p-3 transition-colors hover:bg-muted/15 sm:grid-cols-[32px_1fr]">
          <span className="grid size-7 place-items-center rounded-lg border border-border/45 bg-muted/50 font-mono text-[10px]">
            {String(index + 1).padStart(2, "0")}
          </span>
          <div>
            <h2 className="text-xs font-semibold">{runbook.title}</h2>
            <div className="mt-2 whitespace-pre-line text-[11px] leading-5 text-muted-foreground">{runbook.body}</div>
          </div>
        </article>
      ))}
    </section>
  )
}
