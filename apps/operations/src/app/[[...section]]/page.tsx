import { readFile } from "node:fs/promises"
import path from "node:path"
import { OperationsConsole } from "@/components/operations/operations-console"

export default async function OperationsPage({ params }: { params: Promise<{ section?: string[] }> }) {
  const { section = [] } = await params
  return <OperationsConsole section={section} runbooks={await loadRunbooks()} />
}

const files = [
  "jetstream-disconnect-reconnect.md",
  "live-process-stalled-ingestion.md",
  "finding-last-safe-checkpoint.md",
  "confirming-and-scoping-a-gap.md",
  "running-and-validating-backfills.md",
  "tap-shadow-and-cutover.md",
  "appview-latency-errors.md",
  "client-cache-versus-appview-staleness.md",
  "disabling-rollback-telemetry.md",
]

async function loadRunbooks() {
  return Promise.all(
    files.map(async (file) => {
      const markdown = await readFile(path.resolve(process.cwd(), "../../docs/runbooks/operations", file), "utf8")
      const [heading = file, ...lines] = markdown.trim().split("\n")
      return { slug: file.replace(/\.md$/, ""), title: heading.replace(/^#\s+/, ""), body: lines.join("\n").trim() }
    }),
  )
}
