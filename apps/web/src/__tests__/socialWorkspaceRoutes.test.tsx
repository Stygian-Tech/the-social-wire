import { describe, expect, it } from "bun:test";
import { Suspense, type ReactElement } from "react";
import Bookmarks from "@/app/social/bookmarks/page";
import Explore from "@/app/social/explore/page";
import Notifications from "@/app/social/notifications/page";
import Messages from "@/app/social/messages/page";
import Lists from "@/app/social/lists/page";
import Feeds from "@/app/social/feeds/page";
import { SocialBookmarks } from "@/components/Social/SocialBookmarks";
import { SocialExplore } from "@/components/Social/SocialExplore";
import { SocialNotifications } from "@/components/Social/SocialNotifications";
import { SocialMessages } from "@/components/Social/SocialMessages";
import { SocialLists } from "@/components/Social/SocialLists";
import { SocialFeedDirectory } from "@/components/Social/SocialFeedDirectory";

describe("Social Workspace Routes", () => {
 for (const [name, Page, Component] of [["Bookmarks", Bookmarks, SocialBookmarks], ["Explore", Explore, SocialExplore], ["Notifications", Notifications, SocialNotifications], ["Messages", Messages, SocialMessages], ["Lists", Lists, SocialLists], ["Feeds", Feeds, SocialFeedDirectory]] as const) {
  it(`loads ${name} as a working workspace inside the Social shell`, () => {
   const page = Page() as ReactElement<{ children: ReactElement }>;
   expect(page.type).toBe(Suspense);
   expect(page.props.children.type).toBe(Component);
  });
 }
});
