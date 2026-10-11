import { ChartNoAxesCombined, FilePenLine, Radio, Video } from "lucide-react";
import { SidebarGroup, SidebarGroupLabel, SidebarMenu, SidebarMenuButton, SidebarMenuItem } from "@/components/ui/sidebar";

const tools = [
  { title: "Articles", href: "/articles", icon: FilePenLine },
  { title: "Live Post", href: "/live-post", icon: Radio },
  { title: "Livestream", href: "/livestream", icon: Video },
  { title: "Analytics", href: "/analytics", icon: ChartNoAxesCombined },
] as const;

export function SidebarToolsSection({ pathname, onNavigate }: { pathname: string; onNavigate: (href: string) => void }) {
  return <SidebarGroup className="pb-1 pt-1">
    <SidebarGroupLabel>Tools</SidebarGroupLabel>
    <SidebarMenu className="gap-0.5" aria-label="Tools">
      {tools.map(({ title, href, icon: Icon }) => {
        const active = pathname === href || pathname.startsWith(`${href}/`);
        return <SidebarMenuItem key={href}><SidebarMenuButton type="button" tooltip={title} isActive={active} aria-current={active ? "page" : undefined} onClick={() => onNavigate(href)}><Icon aria-hidden="true" /><span>{title}</span></SidebarMenuButton></SidebarMenuItem>;
      })}
    </SidebarMenu>
  </SidebarGroup>;
}
