export function BackfillMetric({ label, value, tone }: { label: string; value: string; tone?: "danger" }) {
  return (
    <div className="bg-popover p-3">
      <dt className="text-muted-foreground">{label}</dt>
      <dd className={`mt-1 font-mono text-sm ${tone === "danger" ? "text-destructive" : ""}`}>{value}</dd>
    </div>
  )
}
