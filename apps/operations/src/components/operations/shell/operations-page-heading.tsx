import { operationsNav } from "@/components/operations/shell/operations-navigation"

export function OperationsPageHeading({ current }: { current: string }) {
  const label =
    operationsNav.find(([key]) => key === current)?.[1] ?? (current === "traces" ? "Trace Detail" : "Overview")
  return (
    <div className="mb-3 flex items-center gap-3">
      <h1 className="text-lg font-semibold tracking-tight">{label}</h1>
    </div>
  )
}
