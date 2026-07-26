"use client"

import { useQuery, useQueryClient } from "@tanstack/react-query"
import { Activity } from "lucide-react"
import { useRouter } from "next/navigation"
import { useCallback, useEffect, useRef, useState } from "react"
import { BackfillSheet } from "@/components/operations/backfills/backfill-sheet"
import { OperationsDataStatus } from "@/components/operations/dashboard/operations-data-status"
import { OverviewSkeleton } from "@/components/operations/dashboard/overview-skeleton"
import { GapInvestigationSheet } from "@/components/operations/gaps/gap-investigation-sheet"
import { OperationsLoadingScreen } from "@/components/operations/shell/operations-loading-screen"
import { MobileOperationsNav } from "@/components/operations/shell/operations-mobile-nav"
import { operationsNav } from "@/components/operations/shell/operations-navigation"
import { OperationsPageHeading } from "@/components/operations/shell/operations-page-heading"
import { OperationsRouteContent } from "@/components/operations/shell/operations-route-content"
import { OperationsTopBar } from "@/components/operations/shell/operations-top-bar"
import type { Runbook } from "@/components/operations/shell/operations-view-types"
import { OperatorSignIn } from "@/components/operations/sign-in"
import { Button } from "@/components/ui/button"
import { Toast } from "@/components/ui/toast"
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarHeader,
  SidebarInset,
  SidebarNavButton,
  SidebarProvider,
  SidebarTrigger,
} from "@/components/ui/sidebar"
import { operationsEnvironment } from "@/lib/app-environment"
import { useOperationsAuth } from "@/lib/auth-context"
import {
  fetchAlerts,
  fetchBackfills,
  fetchCommands,
  fetchGaps,
  fetchIngestionEndpoints,
  fetchMetrics,
  fetchOverview,
  fetchRecentTraces,
  OperationsForbiddenError,
  type BackfillListView,
  type AlertListView,
  type GapListView,
} from "@/lib/operations-api"
import type { Gap, Overview, PageInfo } from "@/lib/operations-types"
import { eventAffectsRoute, eventAffectsSupportData } from "@/lib/operations-event-routing"
import { useDocumentVisibility } from "@/lib/use-document-visibility"
import { type EventStreamState, useOperationsEventStream } from "@/lib/use-operations-event-stream"
import { nextOperationsPage, previousOperationsPage } from "@/lib/operations-pagination"
import {
  DEFAULT_LIVE_FALLBACK_POLL_MILLISECONDS,
  liveRoutePollInterval,
} from "@/lib/operations-refresh-policy"
import { useVisibilityAwareClock } from "@/lib/use-visibility-aware-clock"

export function OperationsConsole({ section, runbooks }: { section: string[]; runbooks: Runbook[] }) {
  const router = useRouter()
  const queryClient = useQueryClient()
  const auth = useOperationsAuth()
  const demo = process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE === "1"
  const environment = operationsEnvironment()
  const visible = useDocumentVisibility()
  const now = useVisibilityAwareClock(visible)
  const referenceTime = new Date(now).toISOString()
  const eventStreamStateRef = useRef<EventStreamState>("disabled")
  const fallbackPollMillisecondsRef = useRef(DEFAULT_LIVE_FALLBACK_POLL_MILLISECONDS)
  const [autoRefresh, setAutoRefresh] = useState(true)
  const [demoSessionActive, setDemoSessionActive] = useState(true)
  const [selectedGap, setSelectedGap] = useState<Gap>()
  const [investigationGap, setInvestigationGap] = useState<Gap>()
  const [refreshNotice, setRefreshNotice] = useState<{
    title: string
    description: string
    tone: "success" | "error"
  }>()
  const [pagination, setPagination] = useState<{
    route: string
    cursor?: string
    history: Array<string | undefined>
  }>({ route: "overview", history: [] })
  const current = section[0] || "overview"
  const gapView: GapListView = section[1] === "history" ? "history" : "active"
  const backfillView: BackfillListView =
    section[1] === "needs_attention" || section[1] === "history" ? section[1] : "active"
  const alertView: AlertListView = section[1] === "history" ? "history" : "active"
  const routeKey =
    current === "gaps"
      ? `${current}/${gapView}`
      : current === "backfills"
        ? `${current}/${backfillView}`
        : current === "alerts"
          ? `${current}/${alertView}`
          : current
  const listCursor = pagination.route === routeKey ? pagination.cursor : undefined
  const cursorHistory = pagination.route === routeKey ? pagination.history : []
  const detailRoute =
    current === "ingestion" ||
    current === "gaps" ||
    current === "backfills" ||
    current === "alerts" ||
    current === "appview" ||
    current === "commands" ||
    current === "endpoints"
  const historyRoute =
    (current === "gaps" && gapView === "history") ||
    (current === "backfills" && backfillView === "history") ||
    (current === "alerts" && alertView === "history")
  const chartRoute = current === "overview" || current === "ingestion"
  const supportRoute = current === "overview" || current === "ingestion" || (current === "alerts" && alertView === "active")
  const authenticated = demo || Boolean(auth.session)

  const overview = useQuery({
    queryKey: ["operations-overview", environment],
    queryFn: () => fetchOverview(auth.session),
    enabled: authenticated,
    refetchInterval: () =>
      autoRefresh && visible && eventStreamStateRef.current !== "live"
        ? fallbackPollMillisecondsRef.current
        : false,
    refetchIntervalInBackground: false,
    refetchOnWindowFocus: true,
    staleTime: 4_000,
    placeholderData: (previous) => previous,
  })
  const detail = useQuery({
    queryKey: ["operations-route", environment, routeKey, listCursor],
    queryFn: async () => {
      if (current === "ingestion")
        return { kind: "gaps" as const, response: await fetchGaps(auth.session, "active") }
      if (current === "gaps")
        return { kind: "gaps" as const, response: await fetchGaps(auth.session, gapView, listCursor) }
      if (current === "backfills")
        return {
          kind: "backfills" as const,
          response: await fetchBackfills(auth.session, backfillView, listCursor),
        }
      if (current === "alerts")
        return {
          kind: "alerts" as const,
          response: await fetchAlerts(auth.session, alertView, listCursor),
        }
      if (current === "appview")
        return {
          kind: "traces" as const,
          response: await fetchRecentTraces(auth.session, listCursor),
        }
      if (current === "commands")
        return { kind: "commands" as const, response: await fetchCommands(auth.session, listCursor) }
      if (current === "endpoints")
        return {
          kind: "endpoints" as const,
          response: await fetchIngestionEndpoints(auth.session, listCursor),
        }
      return { kind: "none" as const }
    },
    enabled: authenticated && detailRoute && (current !== "appview" || Boolean(overview.data)),
    refetchInterval: () =>
      liveRoutePollInterval({
        autoRefresh,
        visible,
        eventStreamState: eventStreamStateRef.current,
        fallbackMilliseconds: fallbackPollMillisecondsRef.current,
      }),
    refetchIntervalInBackground: false,
    refetchOnWindowFocus: !historyRoute,
    staleTime: 4_000,
  })
  const support = useQuery({
    queryKey: ["operations-support", environment],
    queryFn: async () => {
      const [commands, endpoints] = await Promise.all([
        fetchCommands(auth.session),
        fetchIngestionEndpoints(auth.session),
      ])
      return { commands, endpoints }
    },
    enabled: authenticated && supportRoute,
    refetchInterval: () =>
      liveRoutePollInterval({
        autoRefresh,
        visible,
        eventStreamState: eventStreamStateRef.current,
        fallbackMilliseconds: fallbackPollMillisecondsRef.current,
      }),
    refetchIntervalInBackground: false,
    refetchOnWindowFocus: true,
    staleTime: 4_000,
    placeholderData: (previous) => previous,
  })
  const metrics = useQuery({
    queryKey: ["operations-metrics", environment],
    queryFn: () => fetchMetrics(auth.session),
    enabled: authenticated && chartRoute,
    refetchInterval: autoRefresh && visible ? 60_000 : false,
    refetchIntervalInBackground: false,
    refetchOnWindowFocus: true,
    staleTime: 55_000,
    placeholderData: (previous) => previous,
  })
  const handleOperationsEvent = useCallback((event: Parameters<typeof eventAffectsRoute>[0]) => {
    void queryClient.invalidateQueries({ queryKey: ["operations-overview", environment] })
    if (detailRoute && eventAffectsRoute(event, routeKey))
      void queryClient.invalidateQueries({ queryKey: ["operations-route", environment, routeKey] })
    if (supportRoute && eventAffectsSupportData(event))
      void queryClient.invalidateQueries({ queryKey: ["operations-support", environment] })
  }, [detailRoute, environment, queryClient, routeKey, supportRoute])
  const handleEventStreamSnapshot = useCallback(async () => {
    await Promise.all([
      queryClient.invalidateQueries({ queryKey: ["operations-overview", environment] }),
      ...(detailRoute
        ? [queryClient.invalidateQueries({ queryKey: ["operations-route", environment, routeKey] })]
        : []),
      ...(supportRoute
        ? [queryClient.invalidateQueries({ queryKey: ["operations-support", environment] })]
        : []),
    ])
  }, [detailRoute, environment, queryClient, routeKey, supportRoute])
  const eventStreamState = useOperationsEventStream({
    enabled: autoRefresh && visible && Boolean(overview.data?.capabilities?.eventStream?.enabled),
    session: auth.session,
    path: overview.data?.capabilities?.eventStream?.path ?? "/v1/operations/events/stream",
    retryMilliseconds: overview.data?.capabilities?.eventStream?.retryMilliseconds,
    onEvent: handleOperationsEvent,
    onLive: handleEventStreamSnapshot,
    onCursorExpired: handleEventStreamSnapshot,
  })
  useEffect(() => {
    eventStreamStateRef.current = eventStreamState
    fallbackPollMillisecondsRef.current = Math.max(
      1_000,
      overview.data?.capabilities?.eventStream?.fallbackPollMilliseconds ??
        DEFAULT_LIVE_FALLBACK_POLL_MILLISECONDS,
    )
  }, [eventStreamState, overview.data?.capabilities?.eventStream?.fallbackPollMilliseconds])

  useEffect(() => {
    if (overview.error instanceof OperationsForbiddenError) auth.setForbidden(true)
  }, [overview.error, auth])

  if (auth.loading) return <OperationsLoadingScreen />
  if (!auth.session && (!demo || !demoSessionActive)) return <OperatorSignIn />

  const data = mergeMetricsData(
    mergeSupportData(mergeDetailData(overview.data, detail.data), support.data),
    metrics.data,
  )
  const page = current === "ingestion" ? undefined : detailPage(detail.data)
  const routeEvidenceLoading =
    (detailRoute && detail.isLoading && !detail.data) ||
    (chartRoute && metrics.isLoading && !metrics.data) ||
    (supportRoute && support.isLoading && !support.data)
  const recoveryEnabled = !demo && (data?.capabilities?.recovery.enabled ?? false)
  const selectedGapEvidence = selectedGap
    ? data?.gaps?.find((candidate) => candidate.id === selectedGap.id) ?? selectedGap
    : undefined

  return (
    <SidebarProvider>
      <Sidebar>
        <SidebarHeader>
          <div className="flex min-w-0 items-center gap-2">
            <span className="grid size-7 shrink-0 place-items-center text-primary">
              <Activity className="size-5" />
            </span>
            <div className="min-w-0">
              <p className="truncate text-xs font-semibold">The Social Wire</p>
              <p className="ops-label">Operations</p>
            </div>
          </div>
        </SidebarHeader>
        <SidebarContent>
          <nav aria-label="Operations">
            <div className="grid gap-1">
              {operationsNav.map(([key, label, Icon]) => (
                <SidebarNavButton
                  key={key}
                  active={current === key}
                  icon={<Icon className="size-3.5" />}
                  onClick={() => router.push(key === "overview" ? "/" : `/${key}`)}
                >
                  {label}
                </SidebarNavButton>
              ))}
            </div>
          </nav>
        </SidebarContent>
        <SidebarFooter>
          <SidebarTrigger />
        </SidebarFooter>
      </Sidebar>
      <SidebarInset>
        <OperationsTopBar
          environment={environment}
          autoRefresh={autoRefresh}
          setAutoRefresh={setAutoRefresh}
          refreshedAt={data?.refreshedAt}
          refreshing={overview.isFetching || detail.isFetching || metrics.isFetching || support.isFetching}
          onRefresh={() => {
            void Promise.all([
              overview.refetch(),
              ...(detailRoute ? [detail.refetch()] : []),
              ...(chartRoute ? [metrics.refetch()] : []),
              ...(supportRoute ? [support.refetch()] : []),
            ]).then((results) => {
              const failed = results.find((result) => result.isError)
              setRefreshNotice(
                failed
                  ? {
                      title: "Refresh Failed",
                      description: failed.error?.message ?? "Fresh operational evidence could not be loaded.",
                      tone: "error",
                    }
                  : {
                      title: "Refresh Complete",
                      description: "The visible route reloaded its current evidence successfully.",
                      tone: "success",
                    },
              )
            })
          }}
          operator={auth.session?.did ?? "did:plc:demo-operator"}
          overview={data}
          demo={demo}
          referenceTime={referenceTime}
          onSignOut={async () => {
            await auth.signOut()
            if (demo) setDemoSessionActive(false)
          }}
        />
        <OperationsDataStatus
          overview={data}
          autoRefresh={autoRefresh}
          requestFailed={overview.isError}
          detailFallback={
            (detailRoute && detail.isError) ||
            (chartRoute && metrics.isError) ||
            (supportRoute && support.isError)
          }
          eventStreamState={eventStreamState}
          now={now}
        />
        <MobileOperationsNav current={current} />
        <div className="min-w-0 p-3 sm:p-4">
          <OperationsPageHeading current={current} />
          {overview.isLoading || !data || routeEvidenceLoading ? (
            <OverviewSkeleton />
          ) : (
            <OperationsRouteContent
              current={current}
              traceId={section[1]}
              lifecycleView={section[1]}
              data={data}
              environment={environment}
              runbooks={runbooks}
              onSelectGap={setSelectedGap}
              onInvestigateGap={setInvestigationGap}
              recoveryEnabled={recoveryEnabled}
              operatorMutationsEnabled={!demo}
              referenceTime={referenceTime}
            />
          )}
          {detailRoute && (page?.nextCursor || cursorHistory.length > 0 || page?.totalCount !== undefined) ? (
            <nav aria-label={`${current} pagination`} className="mt-3 flex items-center justify-end gap-2 text-[10px]">
              {page?.totalCount !== undefined ? (
                <span className="mr-auto text-muted-foreground">{page.totalCount.toLocaleString()} total</span>
              ) : null}
              <Button
                size="sm"
                variant="outline"
                disabled={cursorHistory.length === 0 || detail.isFetching}
                onClick={() => {
                  setPagination((state) => previousOperationsPage(state, routeKey))
                }}
              >
                Previous
              </Button>
              <Button
                size="sm"
                variant="outline"
                disabled={!page?.nextCursor || detail.isFetching}
                onClick={() => {
                  setPagination(nextOperationsPage(routeKey, page!.nextCursor!, listCursor, cursorHistory))
                }}
              >
                Next
              </Button>
            </nav>
          ) : null}
          {overview.error && !(overview.error instanceof OperationsForbiddenError) ? (
            <p role="alert" className="mt-3 text-xs text-destructive">
              {overview.error.message}
            </p>
          ) : null}
        </div>
      </SidebarInset>
      <BackfillSheet
        key={`${environment}-${selectedGapEvidence?.id ?? "none"}`}
        gap={selectedGapEvidence}
        environment={environment}
        open={Boolean(selectedGapEvidence)}
        mutationsEnabled={recoveryEnabled}
        recoveryModes={data?.capabilities.recoveryModes}
        onOpenChange={(open) => {
          if (!open) setSelectedGap(undefined)
        }}
      />
      <GapInvestigationSheet
        gap={investigationGap}
        open={Boolean(investigationGap)}
        mutationsEnabled={recoveryEnabled}
        onOpenChange={(open) => {
          if (!open) setInvestigationGap(undefined)
        }}
        onBackfill={(gap) => {
          setInvestigationGap(undefined)
          setSelectedGap(gap)
        }}
      />
      {refreshNotice ? <Toast {...refreshNotice} onClose={() => setRefreshNotice(undefined)} /> : null}
    </SidebarProvider>
  )
}

type DetailData =
  | { kind: "gaps"; response: Awaited<ReturnType<typeof fetchGaps>> }
  | { kind: "backfills"; response: Awaited<ReturnType<typeof fetchBackfills>> }
  | { kind: "alerts"; response: Awaited<ReturnType<typeof fetchAlerts>> }
  | { kind: "traces"; response: Awaited<ReturnType<typeof fetchRecentTraces>> }
  | { kind: "commands"; response: Awaited<ReturnType<typeof fetchCommands>> }
  | { kind: "endpoints"; response: Awaited<ReturnType<typeof fetchIngestionEndpoints>> }
  | { kind: "none" }
  | undefined

function mergeDetailData(overview: Overview | undefined, detail: DetailData) {
  if (!overview || !detail) return overview
  if (detail.kind === "gaps")
    return {
      ...overview,
      gaps: detail.response.gaps,
      evidence: { ...overview.evidence, gaps: detail.response.evidence },
    }
  if (detail.kind === "backfills")
    return {
      ...overview,
      backfills: detail.response.backfills,
      evidence: { ...overview.evidence, backfills: detail.response.evidence },
    }
  if (detail.kind === "alerts")
    return {
      ...overview,
      alerts: detail.response.alerts,
      evidence: { ...overview.evidence, alerts: detail.response.evidence },
    }
  if (detail.kind === "traces")
    return {
      ...overview,
      recentTraces: detail.response.traces,
      evidence: { ...overview.evidence, traces: detail.response.evidence },
    }
  if (detail.kind === "commands")
    return {
      ...overview,
      commands: detail.response.commands,
      evidence: { ...overview.evidence, commands: detail.response.evidence },
    }
  if (detail.kind === "endpoints")
    return {
      ...overview,
      jetstreamEndpoints: detail.response.endpoints,
      evidence: { ...overview.evidence, endpoints: detail.response.evidence },
    }
  return overview
}

function mergeSupportData(
  overview: Overview | undefined,
  support:
    | {
        commands: Awaited<ReturnType<typeof fetchCommands>>
        endpoints: Awaited<ReturnType<typeof fetchIngestionEndpoints>>
      }
    | undefined,
) {
  if (!overview || !support) return overview
  return {
    ...overview,
    commands: support.commands.commands,
    jetstreamEndpoints: support.endpoints.endpoints,
    evidence: {
      ...overview.evidence,
      commands: support.commands.evidence,
      endpoints: support.endpoints.evidence,
    },
  }
}

function mergeMetricsData(
  overview: Overview | undefined,
  metrics: Awaited<ReturnType<typeof fetchMetrics>> | undefined,
) {
  if (!overview || !metrics) return overview
  return {
    ...overview,
    metricRollups: metrics.rollups,
    evidence: { ...overview.evidence, metrics: metrics.evidence },
  }
}

function detailPage(detail: DetailData): PageInfo | undefined {
  if (!detail || detail.kind === "none") return undefined
  return { nextCursor: detail.response.nextCursor ?? undefined, totalCount: detail.response.totalCount }
}
