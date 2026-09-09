// Build in a fresh process: Bun's in-process resolver can reuse Node import choices from tests.
import adapt from "../../../scripts/pds-proof-browser-dependencies.cjs";
const result = await Bun.build({ entrypoints: [new URL("./pdsProofBrowserEntry.ts", import.meta.url).pathname],
  target: "browser", format: "iife", minify: true,
  define: { "process.env.LOG_ENABLED": '"0"', "process.env.LOG_DESTINATION": "undefined", "process.env.LOG_LEVEL": '"silent"', "process.env.LOG_SYSTEMS": "undefined" },
  plugins: [{ name: "browser-proof-adapters", setup(build) {
    build.onLoad({ filter: /@atproto\/(?:common\/dist\/(?:index|logger)|repo\/dist\/car)\.js$/ }, async args =>
      ({ contents: adapt.call({ resourcePath: args.path }, await Bun.file(args.path).text()), loader: "js" }));
  } }],
});
if (!result.success) { console.error(result.logs.map(String)); process.exit(1); }
process.stdout.write(await result.outputs[0].text());
