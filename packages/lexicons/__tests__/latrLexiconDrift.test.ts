import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const latrPackagesRoot = join(import.meta.dir, "../../../node_modules/latr-packages");
const canonicalLexicon = join(
  latrPackagesRoot,
  "packages/lexicons/link.latr.saved.item.json"
);
const socialWireLexicon = join(
  import.meta.dir,
  "../link.latr.saved.item.json"
);

describe("link.latr.saved.item lexicon drift", () => {
  it("matches latr-packages canonical schema", () => {
    const canonical = JSON.parse(readFileSync(canonicalLexicon, "utf8"));
    const local = JSON.parse(readFileSync(socialWireLexicon, "utf8"));
    expect(local).toEqual(canonical);
  });
});
