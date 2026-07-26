import { DataColumnHeaders } from "@/components/operations/data-column-headers"
import { OperationsSection } from "@/components/operations/operations-section"
import { Badge } from "@/components/ui/badge"
import { Table, TableBody, TableCell, TableHeader, TableRow } from "@/components/ui/table"
import { effectiveServiceHealth, healthLabel, serviceHeartbeatIsFresh, type HealthDimension } from "@/lib/observability-values"
import type { Health, Overview, ServiceState } from "@/lib/operations-types"

const dimensions: HealthDimension[] = ["liveness", "readiness", "freshness", "completeness"]

function HealthBadge({ state }: { state: Health }) {
  return <Badge tone={state === "healthy" ? "success" : state === "unknown" ? "neutral" : state === "degraded" ? "warning" : "danger"}>{healthLabel(state)}</Badge>
}

function ServiceEvidence({ service, reference }: { service: ServiceState; reference: string }) {
  const fresh = serviceHeartbeatIsFresh(service, reference)
  return (
    <>
      {dimensions.map((dimension) => (
        <div key={dimension}>
          <dt className="capitalize text-muted-foreground">{dimension}</dt>
          <dd className="mt-1"><HealthBadge state={effectiveServiceHealth(service, dimension, reference)} /></dd>
        </div>
      ))}
      <div className="col-span-2">
        <dt className="text-muted-foreground">Heartbeat</dt>
        <dd className="mt-1">{new Date(service.heartbeatAt).toLocaleString()} · {fresh ? "inside 45s budget" : "expired / invalid"}</dd>
      </div>
    </>
  )
}

export function ServiceTable({ data, referenceTime = data.refreshedAt }: { data: Overview; referenceTime?: string }) {
  return (
    <OperationsSection title="Service State" description="A stale or invalid heartbeat forces every reported dimension to Unknown.">
      {data.services.length === 0 ? (
        <p className="p-6 text-center text-xs text-muted-foreground">No service heartbeats are available.</p>
      ) : (
        <>
          <div className="grid gap-2 p-3 md:hidden">
            {data.services.map((service) => (
              <article key={`${service.service}-${service.instanceId}`} className="rounded-md border bg-background p-3">
                <header className="flex items-start justify-between gap-3">
                  <h3 className="text-xs font-semibold">{service.service}</h3>
                  <span className="break-all font-mono text-[9px] text-muted-foreground">{service.instanceId}</span>
                </header>
                <dl className="mt-3 grid grid-cols-2 gap-3 text-[10px]">
                  <ServiceEvidence service={service} reference={referenceTime} />
                </dl>
              </article>
            ))}
          </div>
          <div className="hidden md:block">
            <Table>
              <TableHeader>
                <TableRow>
                  <DataColumnHeaders labels={["Service", "Instance", "Liveness", "Readiness", "Freshness", "Completeness", "Version", "Heartbeat Evidence"]} />
                </TableRow>
              </TableHeader>
              <TableBody>
                {data.services.map((service) => (
                  <TableRow key={`${service.service}-${service.instanceId}`}>
                    <TableCell className="font-medium">{service.service}</TableCell>
                    <TableCell className="font-mono">{service.instanceId}</TableCell>
                    {dimensions.map((dimension) => (
                      <TableCell key={dimension}><HealthBadge state={effectiveServiceHealth(service, dimension, referenceTime)} /></TableCell>
                    ))}
                    <TableCell className="font-mono">{service.version ?? "—"}</TableCell>
                    <TableCell>
                      {new Date(service.heartbeatAt).toLocaleTimeString()} · {serviceHeartbeatIsFresh(service, referenceTime) ? "Fresh" : "Expired"}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        </>
      )}
    </OperationsSection>
  )
}
