"use client";

import { Avatar } from "@/components/shared/Avatar";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { useViewerProfile } from "@/hooks/useViewerProfile";
import { socialHttpsUrl } from "@/components/Social/socialUrls";

export function ProfileInformation() {
  const profile = useViewerProfile();
  const viewer = profile.data;
  const name = viewer?.displayName?.trim() || viewer?.handle || "Your Profile";
  const banner = socialHttpsUrl(viewer?.banner);
  const counts = [
    { label: "Posts", value: viewer?.postsCount },
    { label: "Followers", value: viewer?.followersCount },
    { label: "Following", value: viewer?.followsCount },
  ];

  return <section id="profile" aria-labelledby="profile-heading" className="scroll-mt-16">
    <div className="mx-auto flex max-w-2xl flex-col items-center gap-4 pb-6 text-center">
      {profile.isLoading ? <div role="status" aria-label="Loading Profile" className="flex flex-col gap-4">
        <h2 id="profile-heading" className="sr-only">Your Profile</h2>
        <Skeleton className="h-32 w-full rounded-xl" /><Skeleton className="size-20 rounded-full" /><Skeleton className="h-6 w-48" />
      </div> : viewer ? <>
        {banner ? (
          /* eslint-disable-next-line @next/next/no-img-element -- Display original remote PDS media. */
          <img src={banner} alt="" referrerPolicy="no-referrer" className="h-36 w-full object-cover sm:h-48" />
        ) : null}
        <Avatar src={viewer.avatar} alt={name} size={96} className={`shrink-0 ring-4 ring-background ${banner ? "-mt-12" : "mt-6"}`} />
        <div className="min-w-0 px-4">
          <h2 id="profile-heading" className="break-words text-2xl font-bold">{name}</h2>
          {viewer.handle ? <p className="break-all text-sm text-muted-foreground">{viewer.handle.startsWith("did:") ? viewer.handle : `@${viewer.handle}`}</p> : null}
        </div>
        {viewer.description ? <p className="max-w-xl whitespace-pre-line break-words px-4 text-sm leading-6">{viewer.description}</p> : null}
        <dl className="flex flex-wrap justify-center gap-x-6 gap-y-2 px-4 text-sm">
          {counts.filter(count => count.value !== undefined).map(count => <div key={count.label} className="flex gap-1.5">
            <dt className="order-2 text-muted-foreground">{count.label}</dt><dd className="order-1 font-semibold">{count.value?.toLocaleString()}</dd>
          </div>)}
        </dl>
      </> : <div role="status" className="flex flex-col items-start gap-3">
        <h2 id="profile-heading" className="text-lg font-semibold">Profile Unavailable</h2>
        <p className="text-sm text-muted-foreground">Your profile information could not be loaded.</p>
        <Button variant="outline" onClick={() => { void profile.refetch(); }}>Retry</Button>
      </div>}
    </div>
  </section>;
}
