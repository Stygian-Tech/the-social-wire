import { JetstreamEndpointStatus } from "@/components/operations/dashboard/jetstream-endpoint-status"
import { OperationsSection } from "@/components/operations/operations-section"
import type { JetstreamEndpoint } from "@/lib/operations-types"

export function EndpointInventory({
  endpoints,
  referenceTime,
}: {
  endpoints: JetstreamEndpoint[]
  referenceTime: string
}) {
  return (
    <OperationsSection
      title="Ingestion Endpoint Inventory"
      description="Environment-scoped active and standby transport observations. Expired observations become Unknown."
    >
      <JetstreamEndpointStatus endpoints={endpoints} reference={referenceTime} />
    </OperationsSection>
  )
}
