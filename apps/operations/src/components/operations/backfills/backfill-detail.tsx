export function BackfillDetail({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="grid grid-cols-[7rem_1fr] gap-2 px-3 py-2">
      <dt className="text-muted-foreground">{label}</dt>
      <dd className={`break-all text-right ${mono ? "font-mono" : ""}`}>{value}</dd>
    </div>
  )
}
