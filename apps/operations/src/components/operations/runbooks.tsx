import type { Runbook } from "@/components/operations/shell/operations-view-types"

export function Runbooks({ runbooks }: { runbooks: Runbook[] }) {
  return (
    <section className="ops-panel divide-y">
      {runbooks.map((runbook, index) => (
        <article id={runbook.slug} key={runbook.slug} className="grid gap-3 p-4 sm:grid-cols-[32px_1fr]">
          <span className="grid size-7 place-items-center rounded-md bg-muted font-mono text-[10px]">
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
