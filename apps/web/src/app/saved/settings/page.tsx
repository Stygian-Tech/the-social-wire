"use client";

import { ArrowLeft, Check, LogIn } from "lucide-react";
import { useRouter } from "next/navigation";
import { Button, buttonVariants } from "@/components/ui/button";
import { READ_LATER_SERVICES } from "@/lib/readLaterServices";
import {
  useConfiguredReadLaterService,
  useSetReadLaterServicePreference,
} from "@/hooks/useReadLaterPreferences";
import { cn } from "@/lib/utils";

export default function ReadLaterSettingsPage() {
  const router = useRouter();
  const { serviceId: configuredServiceId } = useConfiguredReadLaterService();
  const setReadLaterService = useSetReadLaterServicePreference();

  return (
    <div className="flex min-h-0 flex-1 flex-col gap-5 overflow-y-auto overscroll-y-contain p-4 md:p-6">
      <header className="flex shrink-0 items-start justify-between gap-3">
        <div className="min-w-0">
          <h1 className="truncate text-lg font-semibold tracking-tight">
            Read Later Settings
          </h1>
        </div>
        <Button
          type="button"
          variant="outline"
          size="sm"
          className="shrink-0 gap-1.5"
          onClick={() => router.push("/saved")}
        >
          <ArrowLeft className="size-3.5" />
          Saved
        </Button>
      </header>

      <section className="mx-auto flex w-full max-w-2xl flex-col gap-2">
        {READ_LATER_SERVICES.map((service) => {
          const isConfigured = service.id === configuredServiceId;

          return (
            <div
              key={service.id}
              className="flex flex-col gap-3 rounded-md border border-border bg-card p-3 sm:flex-row sm:items-center sm:justify-between"
            >
              <div className="min-w-0 space-y-1">
                <div className="flex flex-wrap items-center gap-2">
                  <h2 className="text-sm font-medium">{service.label}</h2>
                  {isConfigured ? (
                    <span className="rounded-md bg-accent px-1.5 py-0.5 text-[11px] text-accent-foreground">
                      Selected
                    </span>
                  ) : null}
                  {service.connected ? (
                    <span className="rounded-md border border-border px-1.5 py-0.5 text-[11px] text-muted-foreground">
                      Connected
                    </span>
                  ) : (
                    <span className="rounded-md border border-dashed border-border px-1.5 py-0.5 text-[11px] text-muted-foreground">
                      Not Connected
                    </span>
                  )}
                </div>
                <p className="text-xs text-muted-foreground">
                  {service.connected
                    ? "Use saved links stored on your PDS."
                    : `Log in to ${service.label} to load saved links from that service.`}
                </p>
              </div>

              <div className="flex shrink-0 flex-row items-center gap-2">
                {!service.connected && service.loginUrl ? (
                  <a
                    href={service.loginUrl}
                    target="_blank"
                    rel="noopener noreferrer"
                    className={cn(
                      buttonVariants({ variant: "outline", size: "sm" }),
                      "inline-flex gap-1.5 no-underline"
                    )}
                  >
                    <LogIn className="size-3.5" />
                    {service.loginLabel}
                  </a>
                ) : null}
                <Button
                  type="button"
                  variant={isConfigured ? "default" : "outline"}
                  size="sm"
                  className="gap-1.5"
                  disabled={setReadLaterService.isPending}
                  onClick={() => setReadLaterService.mutate(service.id)}
                >
                  {isConfigured ? <Check className="size-3.5" /> : null}
                  {isConfigured ? "Selected" : "Use"}
                </Button>
              </div>
            </div>
          );
        })}
      </section>
    </div>
  );
}
