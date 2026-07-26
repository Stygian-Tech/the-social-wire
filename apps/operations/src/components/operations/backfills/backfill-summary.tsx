export function BackfillSummary({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between px-3 py-2">
      <dt>{label}</dt>
      <dd className="font-mono text-muted-foreground">{value}</dd>
    </div>
  )
}
