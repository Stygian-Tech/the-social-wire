"use client";

import { useRef, useState } from "react";

import { Button } from "@/components/ui/button";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuGroup,
  ContextMenuItem,
  ContextMenuLabel,
  ContextMenuTrigger,
} from "@/components/ui/context-menu";
import {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { useAuth } from "@/hooks/useAuth";
import { useFeedReadAgeActions } from "@/hooks/useFeedReadAgeActions";
import type { ReadAgeOption } from "@/lib/feedReadAgeClient";
import type { GatewayMarkAllReadScope } from "@/lib/publicationProjectionClient";

type FeedMarkReadButtonProps = {
  scope: GatewayMarkAllReadScope | null;
  displayName: string;
  disabled?: boolean;
  onMarkAllRead: () => void;
};

export function FeedMarkReadButton(props: FeedMarkReadButtonProps) {
  const { session } = useAuth();
  // A pending confirmation belongs to one viewer and one feed.
  return (
    <ScopedFeedMarkReadButton
      key={JSON.stringify([session?.did, props.scope])}
      {...props}
    />
  );
}

function ScopedFeedMarkReadButton({
  scope,
  displayName,
  disabled,
  onMarkAllRead,
}: FeedMarkReadButtonProps) {
  const { loadOptions, markBefore } = useFeedReadAgeActions(scope);
  const [menuOpen, setMenuOpen] = useState(false);
  const [options, setOptions] = useState<ReadAgeOption[]>([]);
  const [loading, setLoading] = useState(false);
  const [loadError, setLoadError] = useState(false);
  const [confirmation, setConfirmation] = useState<"all" | ReadAgeOption | null>(null);
  const [pending, setPending] = useState(false);
  const [mutationError, setMutationError] = useState(false);
  const request = useRef(0);

  async function refreshOptions() {
    const current = ++request.current;
    setLoading(true);
    setLoadError(false);
    setOptions([]);
    try {
      const result = await loadOptions();
      if (current === request.current) setOptions(result);
    } catch {
      if (current === request.current) setLoadError(true);
    } finally {
      if (current === request.current) setLoading(false);
    }
  }

  function confirm(action: "all" | ReadAgeOption) {
    setMutationError(false);
    setConfirmation(action);
  }

  const age = confirmation && confirmation !== "all" ? confirmation : null;
  const cutoff = age
    ? new Date(age.before).toLocaleString(undefined, {
        dateStyle: "medium",
        timeStyle: "short",
      })
    : "";

  return (
    <>
      <ContextMenu
        open={menuOpen}
        onOpenChange={(open) => {
          if (disabled || pending || !scope) return;
          setMenuOpen(open);
          if (open) void refreshOptions();
          else request.current += 1;
        }}
      >
        <ContextMenuTrigger
          render={
            <Button
              type="button"
              variant="ghost"
              size="sm"
              className="min-w-0 shrink-0 rounded-md border-0 bg-transparent px-2 text-[11px] font-semibold text-muted-foreground shadow-none hover:bg-muted/50 hover:text-foreground"
              disabled={disabled || pending}
              title="Right-Click or Long-Press to Mark Older Stories As Read"
              onClick={() => confirm("all")}
            />
          }
        >
          Mark All As Read
        </ContextMenuTrigger>
        <ContextMenuContent className="min-w-48" aria-label="Mark Older Stories As Read">
          <ContextMenuGroup>
            <ContextMenuLabel>Older Than</ContextMenuLabel>
            {loading ? <ContextMenuItem disabled>Loading Ages…</ContextMenuItem> : null}
            {loadError ? (
              <ContextMenuItem closeOnClick={false} onClick={() => void refreshOptions()}>
                Couldn’t Load Ages. Retry
              </ContextMenuItem>
            ) : null}
            {!loading && !loadError && options.length === 0 ? (
              <ContextMenuItem disabled>No Older Unread Stories</ContextMenuItem>
            ) : null}
            {options.map((option) => (
              <ContextMenuItem
                key={option.days}
                aria-label={`Older Than ${option.days} ${option.days === 1 ? "Day" : "Days"}, ${option.count} Unread Stories`}
                onClick={() => confirm(option)}
              >
                <span>{option.days} {option.days === 1 ? "Day" : "Days"}</span>
                <span className="ml-auto pl-4 text-xs tabular-nums text-muted-foreground">
                  {option.count.toLocaleString()}
                </span>
              </ContextMenuItem>
            ))}
          </ContextMenuGroup>
        </ContextMenuContent>
      </ContextMenu>
      <Dialog
        open={confirmation !== null}
        onOpenChange={(open) => {
          if (!open && !pending) setConfirmation(null);
        }}
      >
        <DialogContent showCloseButton={!pending}>
          <DialogHeader>
            <DialogTitle>{age ? "Mark Older Stories As Read?" : "Mark All As Read?"}</DialogTitle>
            <DialogDescription>
              {age ? (
                <>Mark unread stories in <span className="font-medium text-foreground">{displayName}</span> published before {cutoff} (your local time) as read. Newer stories stay unread.</>
              ) : (
                <>This marks every unread article in <span className="font-medium text-foreground">{displayName}</span> as read.</>
              )}
            </DialogDescription>
          </DialogHeader>
          {mutationError ? (
            <p role="alert" className="text-sm text-destructive">Couldn’t Mark Stories As Read. Please Try Again.</p>
          ) : null}
          <DialogFooter>
            <DialogClose render={<Button type="button" variant="outline" disabled={pending} />}>
              Cancel
            </DialogClose>
            <Button
              type="button"
              disabled={disabled || pending}
              onClick={async () => {
                if (!age) {
                  onMarkAllRead();
                  setConfirmation(null);
                  return;
                }
                setPending(true);
                setMutationError(false);
                try {
                  await markBefore(age.before);
                  setConfirmation(null);
                } catch {
                  setMutationError(true);
                } finally {
                  setPending(false);
                }
              }}
            >
              {pending ? "Marking…" : age ? "Mark As Read" : "Mark All As Read"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
