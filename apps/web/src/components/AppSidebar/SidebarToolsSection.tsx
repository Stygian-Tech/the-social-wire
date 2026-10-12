import { LockKeyhole } from "lucide-react";
import { useProEntitlements } from "@/hooks/useProEntitlements";
import { CalendarDays, ChartNoAxesCombined, FilePenLine, Radio, UsersRound, Video } from "lucide-react";
import { SidebarGroup, SidebarGroupLabel, SidebarMenu, SidebarMenuButton, SidebarMenuItem } from "@/components/ui/sidebar";

const tools = [
  { title: "Articles", href: "/articles", icon: FilePenLine },
  { title: "Live Post", href: "/live-post", icon: Radio },
  { title: "Livestream", href: "/livestream", icon: Video },
  { title: "Brand Accounts", href: "/brand-accounts", icon: UsersRound },
  { title: "Content Calendar", href: "/content-calendar", icon: CalendarDays },
  { title: "Analytics", href: "/analytics", icon: ChartNoAxesCombined },
] as const;

export function SidebarToolsSection({ pathname, onNavigate }: { pathname: string; onNavigate: (href: string) => void }) {
  const { isPro } = useProEntitlements();
  return <SidebarGroup className="pb-1 pt-1">
    <SidebarGroupLabel>Tools {!isPro ? <span className="ml-2 text-[10px]">Pro</span> : null}</SidebarGroupLabel>
    <SidebarMenu className="gap-0.5" aria-label="Tools">
      {tools.map(({ title, href, icon: Icon }) => {
        const active = pathname === href || pathname.startsWith(`${href}/`);
        return <SidebarMenuItem key={href}><SidebarMenuButton type="button" tooltip={title} isActive={active} aria-current={active ? "page" : undefined} onClick={() => onNavigate(href)}><Icon aria-hidden="true" /><span>{title}</span>{!isPro ? <LockKeyhole aria-hidden="true" className="ml-auto size-3" /> : null}</SidebarMenuButton></SidebarMenuItem>;
      })}
    </SidebarMenu>
  </SidebarGroup>;
}
