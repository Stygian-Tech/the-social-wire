"use client";

import { floatingGlassClasses } from "@/components/shared/floatingChromeStyles";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { MyPublicationsSection } from "./MyPublicationsSection";
import { ProfileTimeline } from "./ProfileTimeline";
import type { ProfileSection } from "@/lib/blueskyProfileClient";

const ownSections = ["posts", "replies", "media", "likes", "publications"] as const;
const otherSections = ["posts", "replies", "media", "likes"] as const;
export function ProfileContent({ actor, own = true }: { actor?: string; own?: boolean }) {
  const sections = own ? ownSections : otherSections;
  const [selected, setSelected] = useState<ProfileSection | "publications">("posts");
  useEffect(() => {
    const sync = () => {
      const section = window.location.hash.slice(1);
      if (sections.some(value => value === section)) setSelected(section as typeof selected);
    };
    sync();
    window.addEventListener("hashchange", sync);
    return () => window.removeEventListener("hashchange", sync);
  }, [sections]);
  return <>
    <nav aria-label="Profile Content" className={`sticky top-2 z-10 m-2 p-3 ${floatingGlassClasses}`}>
      <div className="mx-auto flex max-w-2xl gap-2 overflow-x-auto">
        {sections.map(section => <Button key={section} variant={selected === section ? "default" : "outline"} className="shrink-0 rounded-full" aria-pressed={selected === section} onClick={() => {
          setSelected(section);
          window.history.replaceState(window.history.state, "", `${window.location.pathname}${window.location.search}#${section}`);
        }}>
          {section.charAt(0).toUpperCase() + section.slice(1)}
        </Button>)}
      </div>
    </nav>
    <section aria-label={`${selected.charAt(0).toUpperCase() + selected.slice(1)} Content`}>
      {selected === "publications" ? <MyPublicationsSection /> : <ProfileTimeline key={`${actor ?? "viewer"}:${selected}`} section={selected} actor={actor} />}
    </section>
  </>;
}
