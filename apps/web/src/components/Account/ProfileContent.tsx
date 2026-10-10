"use client";

import { floatingGlassClasses } from "@/components/shared/floatingChromeStyles";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { MyPublicationsSection } from "./MyPublicationsSection";
import { ProfileTimeline } from "./ProfileTimeline";
import type { ProfileSection } from "@/lib/blueskyProfileClient";

const sections = ["posts", "replies", "media", "likes", "publications"] as const;
export function ProfileContent() {
  const [selected, setSelected] = useState<ProfileSection | "publications">("posts");
  useEffect(() => {
    const sync = () => { if (window.location.hash === "#publications") setSelected("publications"); };
    sync();
    window.addEventListener("hashchange", sync);
    return () => window.removeEventListener("hashchange", sync);
  }, []);
  return <>
    <nav aria-label="Profile Content" className={`sticky top-2 z-10 m-2 p-3 ${floatingGlassClasses}`}>
      <div className="mx-auto flex max-w-2xl gap-2 overflow-x-auto">
        {sections.map(section => <Button key={section} variant={selected === section ? "default" : "outline"} className="shrink-0 rounded-full" aria-pressed={selected === section} onClick={() => setSelected(section)}>
          {section.charAt(0).toUpperCase() + section.slice(1)}
        </Button>)}
      </div>
    </nav>
    <section aria-label={`${selected.charAt(0).toUpperCase() + selected.slice(1)} Content`}>
      {selected === "publications" ? <MyPublicationsSection /> : <ProfileTimeline key={selected} section={selected} />}
    </section>
  </>;
}
