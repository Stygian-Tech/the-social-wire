import { afterAll, afterEach, beforeAll, beforeEach } from "bun:test";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

let executable: Promise<string> | undefined;
function buildService() {
  return executable ??= (async () => {
    const root = resolve(dirname(fileURLToPath(import.meta.resolve("@stygian/anypub-kit"))), "../..");
    const output = join(await mkdtemp(join(tmpdir(), "anypub-preparation-")), "server");
    const process = Bun.spawn(["go", "build", "-o", output, "./cmd/anypubkit"], { cwd: root, env: { ...Bun.env, GOTOOLCHAIN: "go1.26.6" }, stdout: "pipe", stderr: "pipe" });
    const [status, stderr] = await Promise.all([process.exited, new Response(process.stderr).text()]);
    if (status !== 0) throw new Error(`Go preparation service build failed: ${stderr}`);
    return output;
  })();
}

/** Publishing acceptance exercises the real pinned Go preparation server and mocked PDS only. */
export function setupGoPreparationService() {
  let process: ReturnType<typeof Bun.spawn>;
  let endpoint = "";
  let originalFetch: typeof fetch;
  beforeAll(async () => {
    const binary = await buildService();
    process = Bun.spawn([binary], { env: { ...Bun.env, PORT: "0" }, stdout: "ignore", stderr: "pipe" });
    const reader = (process.stderr as ReadableStream<Uint8Array>).getReader();
    let log = "";
    try {
      for (;;) {
        const result = await reader.read();
        if (result.done) throw new Error(`Preparation service exited: ${log}`);
        log += new TextDecoder().decode(result.value);
        const port = /listening on .*:(\d+)/.exec(log)?.[1];
        if (port) { endpoint = `http://127.0.0.1:${port}`; break; }
      }
    } finally { reader.releaseLock(); }
  }, 120_000);
  beforeEach(() => {
    originalFetch = globalThis.fetch;
    const requestFetch = originalFetch;
    const transport = (async (input: string | URL | Request, init?: RequestInit) => {
      const target = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
      return requestFetch(target === "/xrpc/tech.stygian.anypub.prepare" ? `${endpoint}${target}` : input, init);
    }) as typeof fetch;
    globalThis.fetch = transport;
  });
  afterEach(() => { globalThis.fetch = originalFetch; });
  afterAll(() => { process?.kill(); });
}
