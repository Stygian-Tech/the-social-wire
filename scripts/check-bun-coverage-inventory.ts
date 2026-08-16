#!/usr/bin/env bun
import { readdirSync, readFileSync, realpathSync } from "node:fs";
import { join, relative } from "node:path";

const [sourceRoot, lcovPath, allowlistPath] = Bun.argv.slice(2);

if (!sourceRoot || !lcovPath || !allowlistPath) {
  console.error(
    "usage: check-bun-coverage-inventory.ts <source-root> <lcov-path> <allowlist-path>",
  );
  process.exit(2);
}

function sourceFiles(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    return entry.isDirectory() ? sourceFiles(path) : [path];
  });
}

function normalize(path: string): string {
  return path.replaceAll("\\", "/");
}

function normalizeReportedSource(path: string): string {
  const normalized = normalize(path);
  if (normalized.startsWith("/")) {
    return normalize(
      relative(realpathSync(process.cwd()), realpathSync(normalized)),
    );
  }
  return normalized.replace(/^\.\//, "");
}

const productionSources = sourceFiles(sourceRoot)
  .filter((path) => /\.(ts|tsx)$/.test(path))
  .filter((path) => !normalize(path).includes("/__tests__/"))
  .filter((path) => !/\.(test|spec|stories)\.(ts|tsx)$/.test(path))
  .filter((path) => !path.endsWith(".d.ts"))
  .map((path) => normalize(relative(process.cwd(), path)))
  .sort();

const reportedSources = new Set(
  [...readFileSync(lcovPath, "utf8").matchAll(/^SF:(.+)$/gm)].map((match) =>
    normalizeReportedSource(match[1]),
  ),
);
const allowlistedSources = new Set(
  readFileSync(allowlistPath, "utf8")
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#")),
);
const missingSources = new Set(
  productionSources.filter((path) => !reportedSources.has(path)),
);

const unexpectedMissing = [...missingSources].filter(
  (path) => !allowlistedSources.has(path),
);
const staleAllowlist = [...allowlistedSources].filter(
  (path) => !missingSources.has(path),
);

if (unexpectedMissing.length || staleAllowlist.length) {
  if (unexpectedMissing.length) {
    console.error("Production sources absent from LCOV and the reviewed allowlist:");
    for (const path of unexpectedMissing) console.error(`  ${path}`);
  }
  if (staleAllowlist.length) {
    console.error("Stale coverage inventory allowlist entries:");
    for (const path of staleAllowlist) console.error(`  ${path}`);
  }
  process.exit(1);
}

const reportedProductionCount = productionSources.length - missingSources.size;
const inventoryPercent =
  productionSources.length === 0
    ? 100
    : (reportedProductionCount / productionSources.length) * 100;
console.log(
  `Coverage inventory: ${reportedProductionCount}/${productionSources.length} production modules (${inventoryPercent.toFixed(1)}%); ${missingSources.size} reviewed omissions.`,
);
