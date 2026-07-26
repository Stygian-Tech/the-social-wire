import { Badge } from "@/components/ui/badge"
import type { Overview } from "@/lib/operations-types"

export function CapabilityStatus({ overview }: { overview: Overview }) {
  const capabilities = overview.capabilities
  if (!capabilities)
    return (
      <section className="ops-panel p-3 text-[10px] text-muted-foreground" aria-label="Operations Capabilities">
        Capability evidence is unavailable. Mutation controls requiring capabilities remain conservative.
      </section>
    )
  const items = [
    ["Telemetry", capabilities.telemetry],
    ["Recovery Global Gate", capabilities.recovery],
    ["Tap Verified Resync", capabilities.recoveryModes.tapVerifiedResync],
    ["Jetstream Replay", capabilities.recoveryModes.jetstreamReplay],
    ["PDS Diagnostic", capabilities.recoveryModes.pdsReconciliation],
    ["Alert Delivery", capabilities.alertDelivery],
    ["Live Event Stream", capabilities.eventStream],
  ] as const
  return (
    <section className="ops-panel grid divide-y sm:grid-cols-2 lg:grid-cols-3" aria-label="Operations Capabilities">
      {items.map(([label, capability]) => (
        <div key={label} className="p-3">
          <div className="flex items-center justify-between gap-2">
            <h2 className="text-[10px] font-semibold">{label}</h2>
            <Badge tone={capability.enabled ? "success" : "warning"}>{capability.enabled ? "Enabled" : "Disabled"}</Badge>
          </div>
          <p className="mt-2 text-[9px] text-muted-foreground">
            {capability.enabled ? "Reported available by the Operations service." : capability.disabledReason ?? "No disabled reason was reported."}
          </p>
        </div>
      ))}
    </section>
  )
}
