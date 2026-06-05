import { cn } from "@/lib/utils";
import { latrGatewayErrorForDisplay } from "@/lib/latrGatewayErrors";

type ListColumnErrorProps = {
  error: unknown;
  fallbackTitle?: string;
  className?: string;
};

/** Narrow-column error panel with headline + optional detail. */
export function ListColumnError({
  error,
  fallbackTitle = "Something went wrong",
  className,
}: ListColumnErrorProps) {
  const { headline, detail } = latrGatewayErrorForDisplay(error, fallbackTitle);

  return (
    <div
      className={cn(
        "min-h-0 max-h-full w-full shrink-0 overflow-y-auto p-3",
        className
      )}
    >
      <div className="w-full min-w-0 rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-destructive">
        <p className="text-sm font-medium leading-snug">{headline}</p>
        {detail ? (
          <p className="mt-1.5 break-words text-xs leading-relaxed text-destructive/90">
            {detail}
          </p>
        ) : null}
      </div>
    </div>
  );
}
