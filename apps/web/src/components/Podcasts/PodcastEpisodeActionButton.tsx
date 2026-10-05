import type { ButtonHTMLAttributes } from "react";
import type { LucideIcon } from "lucide-react";

export function PodcastEpisodeActionButton({ icon: Icon, children, className = "", ...props }: ButtonHTMLAttributes<HTMLButtonElement> & { icon: LucideIcon }) {
  return <button type="button" {...props} className={`inline-flex min-h-8 items-center gap-1.5 rounded border px-2 text-xs hover:bg-accent disabled:opacity-50 pointer-coarse:min-h-11 ${className}`}>
    <Icon className="size-3.5 shrink-0" aria-hidden="true" />
    {children}
  </button>;
}
