import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const latrPackagesRoot = join(import.meta.dir, "../../../node_modules/latr-packages");
const mirrors = [
  ["link.latr.saved.item.json", "../link/latr/saved/item.json"],
  ["link.latr.bookmarks.defs.json", "../link/latr/bookmarks/defs.json"],
  ["link.latr.bookmarks.metadata.json", "../link/latr/bookmarks/metadata.json"],
  ["link.latr.bookmarks.listBookmarks.json", "../link/latr/bookmarks/listBookmarks.json"],
  ["link.latr.bookmarks.getBookmark.json", "../link/latr/bookmarks/getBookmark.json"],
  ["link.latr.bookmarks.saveBookmark.json", "../link/latr/bookmarks/saveBookmark.json"],
  ["link.latr.bookmarks.setState.json", "../link/latr/bookmarks/setState.json"],
  ["link.latr.bookmarks.deleteBookmark.json", "../link/latr/bookmarks/deleteBookmark.json"],
  ["link.latr.bookmarks.migrateLegacy.json", "../link/latr/bookmarks/migrateLegacy.json"],
] as const;

describe("L@tr lexicon drift", () => {
  for (const [canonicalName, localName] of mirrors) {
    it(`${canonicalName} matches latr-packages`, () => {
      const canonical = JSON.parse(
        readFileSync(join(latrPackagesRoot, "packages/lexicons", canonicalName), "utf8")
      );
      const local = JSON.parse(readFileSync(join(import.meta.dir, localName), "utf8"));
      expect(local).toEqual(canonical);
    });
  }
});
