import { afterEach, expect, it, mock, spyOn } from "bun:test";
import { navigateReaderFeed } from "@/lib/readerFeedNavigation";

const restores: Array<() => void> = [];
afterEach(() => { for (const restore of restores.splice(0)) restore(); });

it.each(["sports", "finance", "wire", "circle", "subscribed", "following"] as const)(
  "switches %s from the reader index without a server route transition",
  feed => {
    const history = spyOn(window.history, "pushState").mockImplementation(() => undefined);
    restores.push(() => history.mockRestore());
    const pushRoute = mock(() => undefined);

    navigateReaderFeed("/read", feed, pushRoute);

    // A fresh destination query drops the prior list/folder/topic selection, as full navigation did.
    expect(history).toHaveBeenCalledWith(null, "", `/read?feed=${feed}`);
    expect(pushRoute).not.toHaveBeenCalled();
  },
);

it.each(["/read/at%3Apublication", "/read/", "/saved", "/social"])(
  "retains a full route transition from %s",
  pathname => {
    const history = spyOn(window.history, "pushState").mockImplementation(() => undefined);
    restores.push(() => history.mockRestore());
    const pushRoute = mock(() => undefined);

    navigateReaderFeed(pathname, "finance", pushRoute);

    expect(pushRoute).toHaveBeenCalledWith("/read?feed=finance");
    expect(history).not.toHaveBeenCalled();
  },
);
