export function EnvironmentBanner({ demo }: { demo: boolean }) {
  return (
    <div
      role="note"
      className="flex h-6 items-center justify-center border-b border-warning/35 bg-warning-surface px-3 text-[10px] font-semibold uppercase tracking-[0.16em] text-warning"
    >
      {demo ? "Demo Data · Synthetic Fixtures · Development Environment" : "Development Environment"}
    </div>
  )
}
