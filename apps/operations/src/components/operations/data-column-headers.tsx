import { TableHead } from "@/components/ui/table"
import { Tooltip } from "@/components/ui/tooltip"

export const columnExplanations = {
  Collection: "The ATProto collection represented by this row.",
  "Create (indexed events/sec)": "Successfully indexed create events per second in each closed one-minute bucket.",
  "Update (indexed events/sec)": "Successfully indexed update events per second in each closed one-minute bucket.",
  "Delete (indexed events/sec)": "Successfully indexed delete events per second in each closed one-minute bucket.",
  "All Indexed Events/sec.": "Combined successfully indexed create, update, and delete events per second.",
  "Avg Commit Time (ms)": "Average database commit duration in each retained one-minute bucket.",
  "Max Commit Time (ms)": "Maximum database commit duration in each retained one-minute bucket.",
  "Errors (events/sec)": "Processing errors recorded per second.",
  Time: "The time when this request began.",
  "Request ID": "The identifier for this individual request.",
  "Span ID": "The identifier recorded for this sampled span.",
  "Parent Span": "The recorded parent span identifier, when this span belongs to a nested trace.",
  "Trace ID": "The correlation identifier shared by every span in the request trace.",
  Route: "The API route or operation handled by the span.",
  Operation: "The recorded route template or span operation name.",
  Method: "The HTTP method recorded on the span, when supplied.",
  Status: "The current result or lifecycle state for this row.",
  "Status Class": "The recorded HTTP response class, when supplied by request telemetry.",
  "Total Latency": "Total elapsed time from request start to response completion.",
  "Error Type": "The bounded error category recorded for a failed span.",
  Environment: "The environment dimension recorded on the span.",
  Auth: "The authentication method accepted for the request.",
  Cache: "Whether the request was served from or missed the projection cache.",
  "DB Time": "Time attributed to database work during the request.",
  Query: "The recorded database query or operation name.",
  Duration: "Total elapsed time attributed to this database span.",
  Schema: "The Postgres schema containing this table.",
  Table: "The Postgres table represented by this row.",
  "Estimated Records": "Postgres's estimated number of live rows from pg_stat_user_tables.",
  "Estimated Live Rows": "Postgres statistics estimate of live rows; this is not an exact count.",
  Rows: "The number of records returned or affected by the request.",
  "Resp Freshness": "The age of the data when the response was produced.",
  "View Trace": "Opens the correlated request trace and its component spans.",
  Trace: "Opens the correlated request trace and its component spans.",
  "Normalized Operation": "The bounded route template or operation name, without high-cardinality identifiers.",
  "Span Status": "The result recorded on this sampled span; it is not a request-volume aggregate.",
  "Condition Key": "The stable environment-scoped identity for this concrete alert condition.",
  "HTTP Class": "The actual normalized HTTP response class recorded on the sampled span.",
  Latency: "Total elapsed time recorded for this sampled span.",
  "Accepted (indexed events/sec)": "Events successfully indexed per second in each closed one-minute bucket.",
  "Failed (events/sec)": "Events that recorded a processing failure per second in each closed one-minute bucket.",
  "Avg Event Lag (s)": "Average age of committed events in each retained one-minute bucket.",
  "Max Event Lag (s)": "Maximum age of committed events in each retained one-minute bucket.",
  "Cursor / Time Range (μs)": "The Jetstream cursor interval covered by the detected gap.",
  Reason: "The signal that caused the gap to be detected.",
  Detected: "When the system first recorded the gap.",
  "Affected Collections":
    "The number of ATProto collections attributed to the gap. Unknown means the detector could not determine the collection scope.",
  Action: "The recovery or lifecycle action currently available for this row.",
  "Legal Actions": "Only lifecycle transitions allowed from the row's current versioned state.",
  "Recovery / Lifecycle": "A safe recovery action for the underlying condition and the alert lifecycle action.",
  "Backfill ID": "The stable identifier assigned to this recovery job.",
  "Range (μs)": "The cursor interval the backfill is configured to replay.",
  Progress:
    "Observed processed records as a percentage of the dry-run estimate. Job completion is reported separately and never forces this value to 100%.",
  Processed: "The number of events processed by the recovery job.",
  Rate: "The configured maximum processing rate. This is a limit, not observed throughput.",
  "Checkpoint (μs)": "The latest durable cursor saved by the recovery job.",
  Severity: "The operational impact level assigned to the alert.",
  Rule: "The alerting rule that opened this incident.",
  Summary: "A concise description of the condition that triggered the alert.",
  Opened: "When the alert entered the open state.",
  Delivery: "Webhook delivery attempts and the latest delivery result.",
  Runbook: "The operational procedure associated with this alert.",
  Service: "The distributed service reporting this health state.",
  Instance: "The specific running service instance reporting the heartbeat.",
  Liveness: "Whether the service process is running and responding.",
  Readiness: "Whether the service is ready to accept production work.",
  Freshness: "Whether the service data is within its expected age threshold.",
  Completeness: "Whether known gaps or missing projections affect the service.",
  Version: "The deployed build or release version reported by the service.",
  Heartbeat: "The most recent health heartbeat received from the instance.",
  "Heartbeat Evidence": "The heartbeat time and whether it is still inside the console freshness budget.",
  "Command ID": "The durable identifier assigned to the operator command.",
  "Requested By": "The operator DID that requested the command.",
  "Claimed By": "The service instance that currently owns or completed the command.",
  Updated: "When this lifecycle record was most recently changed.",
  "Failure Reason": "The durable failure category or explanation reported by the command runner.",
} as const

export type DataColumnLabel = keyof typeof columnExplanations

export function DataColumnHeaders({ labels }: { labels: readonly DataColumnLabel[] }) {
  return labels.map((label) => (
    <TableHead key={label}>
      <Tooltip label={columnExplanations[label]}>
        <span
          aria-label={`${label}: ${columnExplanations[label]}`}
          className="cursor-help decoration-dotted underline-offset-4 hover:underline focus-visible:underline focus-visible:outline-none"
          tabIndex={0}
        >
          {label}
        </span>
      </Tooltip>
    </TableHead>
  ))
}
