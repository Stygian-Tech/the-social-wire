import { Activity } from "lucide-react"

export function OperationsLoadingScreen() {
  return (
    <main className="grid min-h-svh place-items-center">
      <div className="text-center">
        <Activity className="mx-auto size-6 animate-pulse text-primary" />
        <p className="mt-2 text-xs text-muted-foreground">Restoring operator session…</p>
      </div>
    </main>
  )
}
