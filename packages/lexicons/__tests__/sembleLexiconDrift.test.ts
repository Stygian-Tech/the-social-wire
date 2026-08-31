import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "bun:test";

const officialRepository = "https://github.com/cosmik-network/semble";
const officialRevision = "a63d60d411946d9f06451ffd830a18a0adcce7f7";
const officialDirectory = "src/modules/atproto/infrastructure/lexicons";

const mirrors = [
  ["defs.json", "52b0177fc79809e28506a97c466cc9b62c1dbb92a5f771fcbd768a6a5fb56506", "network.cosmik.defs"],
  ["card.json", "5361b7a46e68042a8ebc775d4294e9815d6c0d2597751e8ccb1ba33b729642dc", "network.cosmik.card"],
  ["collection.json", "3ec93515112cae61c9a5d29aed2a7304ff3cd44b1198b60322c7c401a021c0bd", "network.cosmik.collection"],
  ["collectionLink.json", "9db9c877d9d15d124dad2b274d1ee6dc14bec4ef993fc7c0747e774a4929a3a4", "network.cosmik.collectionLink"],
  ["collectionLinkRemoval.json", "522b38247cb51c3fdc00fc823aeedeefb4ae42aa23e57366b919a191e06dc9c0", "network.cosmik.collectionLinkRemoval"],
  ["connection.json", "511ed053013bab3eaf7f2aff4b776a24577410b440ac5f838b881ceaf632b5d9", "network.cosmik.connection"],
] as const;

describe("Semble lexicon drift", () => {
  it("pins the official Semble source revision", () => {
    expect(officialRepository).toBe("https://github.com/cosmik-network/semble");
    expect(officialRevision).toBe("a63d60d411946d9f06451ffd830a18a0adcce7f7");
    expect(officialDirectory).toBe("src/modules/atproto/infrastructure/lexicons");
  });

  for (const [name, sha256, nsid] of mirrors) {
    it(`${nsid} matches the pinned official bytes`, () => {
      const bytes = readFileSync(join(import.meta.dir, "../network/cosmik", name));
      expect(createHash("sha256").update(bytes).digest("hex")).toBe(sha256);
      expect(JSON.parse(bytes.toString("utf8")).id).toBe(nsid);
    });
  }
});
