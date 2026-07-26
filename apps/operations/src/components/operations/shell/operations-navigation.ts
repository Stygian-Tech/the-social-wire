import {
  Bell,
  BookOpenText,
  LayoutDashboard,
  ListRestart,
  Network,
  RefreshCw,
  Server,
  Settings2,
  Waypoints,
} from "lucide-react"

export const operationsNav = [
  ["overview", "Overview", LayoutDashboard],
  ["ingestion", "Ingestion", Settings2],
  ["endpoints", "Endpoints", Network],
  ["commands", "Commands", ListRestart],
  ["appview", "AppView", Server],
  ["gaps", "Gaps", Waypoints],
  ["backfills", "Backfills", RefreshCw],
  ["alerts", "Alerts", Bell],
  ["runbooks", "Runbooks", BookOpenText],
] as const
