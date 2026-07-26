"use client"

import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { useState } from "react"
import { OperationsAuthProvider } from "@/lib/auth-context"

export function Providers({ children }: { children: React.ReactNode }) {
  const [queryClient] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: {
            staleTime: 4_000,
            refetchInterval: false,
            refetchIntervalInBackground: false,
            refetchOnWindowFocus: true,
            retry: 1,
          },
        },
      }),
  )
  return (
    <QueryClientProvider client={queryClient}>
      <OperationsAuthProvider>{children}</OperationsAuthProvider>
    </QueryClientProvider>
  )
}
