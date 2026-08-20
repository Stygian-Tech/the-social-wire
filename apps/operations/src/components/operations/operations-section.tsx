export function OperationsSection({
  title,
  description,
  action,
  children,
}: {
  title: React.ReactNode
  description?: React.ReactNode
  action?: React.ReactNode
  children: React.ReactNode
}) {
  return (
    <section className="ops-panel min-w-0 w-full max-w-full overflow-hidden">
      <header className="flex min-h-9 flex-wrap items-center justify-between gap-2 border-b border-border/45 bg-muted/12 px-3 py-2 sm:gap-3">
        <div className="min-w-0">
          <h2 className="text-xs font-semibold">{title}</h2>
          {description ? <p className="mt-1 max-w-5xl text-[11px] leading-4 text-muted-foreground">{description}</p> : null}
        </div>
        {action ? <div className="min-w-0 shrink-0">{action}</div> : null}
      </header>
      {children}
    </section>
  )
}
