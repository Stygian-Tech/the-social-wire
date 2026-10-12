import { Agent } from "@atproto/api";

/** Per-instance labelers keep isolated local networks from changing global SDK safety defaults. */
export class LocalAppViewAgent extends Agent {
  constructor(options: ConstructorParameters<typeof Agent>[0], private readonly localLabelers: readonly string[]) {
    super(options);
  }

  override get appLabelers(): readonly string[] {
    return this.localLabelers;
  }

  override clone(): LocalAppViewAgent {
    return this.copyInto(new LocalAppViewAgent(this.sessionManager, this.localLabelers));
  }
}
