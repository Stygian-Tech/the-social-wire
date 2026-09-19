// Webpack and Turbopack execute this loader as CommonJS.
// eslint-disable-next-line @typescript-eslint/no-require-imports
const path = require("node:path");

// Browser-only adaptation of pinned upstream dependencies. No signature, hash, or
// MST logic is rewritten; only the CAR scheduler and unused common exports change.
module.exports = function pdsProofBrowserDependencies(source) {
  const resource = this.resourcePath.replaceAll("\\", "/");
  const requireCount = (pattern, count) => {
    if ([...source.matchAll(pattern)].length !== count) {
      throw new Error(`Upstream proof dependency changed; review browser adapter before building: ${resource}`);
    }
  };
  if (resource.endsWith("/@atproto/common/dist/index.js")) {
    for (const name of ["fs", "ipld", "streams"]) {
      requireCount(new RegExp(`^export \\* from '\\./${name}\\.js';\\r?$`, "gm"), 1);
    }
    return source.replace(/^export \* from '\.\/(fs|ipld|streams)\.js';\r?\n/gm, "");
  }
  if (resource.endsWith("/@atproto/common/dist/logger.js")) {
    const constants = { LOG_ENABLED: '"0"', LOG_DESTINATION: "undefined", LOG_LEVEL: '"silent"', LOG_SYSTEMS: "undefined" };
    for (const name of Object.keys(constants)) {
      requireCount(new RegExp(`process\\.env\\.${name}\\b`, "g"), name === "LOG_SYSTEMS" ? 2 : 1);
    }
    return source.replace(/process\.env\.(LOG_ENABLED|LOG_DESTINATION|LOG_LEVEL|LOG_SYSTEMS)\b/g, (_, key) => constants[key]);
  }
  if (resource.endsWith("/@atproto/repo/dist/car.js")) {
    requireCount(/^import \{ setImmediate \} from 'node:timers\/promises';\r?$/gm, 1);
    const relative = path.relative(path.dirname(this.resourcePath), path.join(__dirname, "../src/lib/browserAdapters/pdsProofTimer.ts")).split(path.sep).join("/");
    return source.replace(/from 'node:timers\/promises'/g, `from ${JSON.stringify(relative.startsWith(".") ? relative : `./${relative}`)}`);
  }
  throw new Error(`Unreviewed proof dependency requested a browser adapter: ${resource}`);
};
