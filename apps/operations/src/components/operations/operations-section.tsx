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
      <header className="flex min-h-9 items-center justify-between gap-3 border-b px-3 py-2">
        <div className="min-w-0">
          <h2 className="text-xs font-semibold">{title}</h2>
          {description ? <p className="mt-1 text-[9px] text-muted-foreground">{description}</p> : null}
        </div>
        {action}
      </header>
      {children}
    </section>
  )
}
