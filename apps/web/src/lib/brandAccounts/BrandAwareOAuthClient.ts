import { BrowserOAuthClient, OAuthClient, OAuthCallbackError, type BrowserOAuthClientLoadOptions, type BrowserOAuthClientOptions } from "@atproto/oauth-client-browser";
import { assertOAuthDiscoverableClientId, atprotoLoopbackClientMetadata } from "@atproto/oauth-types";
import { BRAND_LINK_STATE_PREFIX, assertBrandAccountAvailable, validateBrandLinkIntent } from "./brandAccountStorage";
/** Preserve the browser's personal-account route while retaining SDK token storage. */
export class BrandAwareOAuthClient extends BrowserOAuthClient {
  constructor(options: BrowserOAuthClientOptions, private readonly primaryDid: () => string | null) { super(options); }
  static async loadForAccounts({ clientId, ...options }: BrowserOAuthClientLoadOptions, primaryDid: () => string | null): Promise<BrandAwareOAuthClient> {
    if (clientId.startsWith("http:")) return new BrandAwareOAuthClient({ ...options, clientMetadata: atprotoLoopbackClientMetadata(clientId) }, primaryDid);
    assertOAuthDiscoverableClientId(clientId);
    const clientMetadata = await OAuthClient.fetchMetadata({ clientId, ...options });
    return new BrandAwareOAuthClient({ ...options, clientMetadata }, primaryDid);
  }
  override revoke(did: string): Promise<void> { return OAuthClient.prototype.revoke.call(this, did); }
  override async callback(params: URLSearchParams, options: Parameters<OAuthClient["callback"]>[1] = {}) {
    const stateKey = params.get("state"), stored = stateKey ? await this.stateStore.get(stateKey) : undefined;
    if (!stored?.appState?.startsWith(BRAND_LINK_STATE_PREFIX)) return super.callback(params, options);
    // Follow the SDK callback sequence using its protected stores and public
    // exchangeCode validator. The extra account guard must precede revoke/store:
    // the regular SDK callback replaces an existing session for the returned DID.
    await this.stateStore.del(stateKey!);
    const appState = stored.appState;
    try {
      validateBrandLinkIntent(appState, this.primaryDid());
      if (params.has("response")) throw new Error("JARM Is Not Supported.");
      if (params.has("error")) throw new OAuthCallbackError(params, undefined, appState);
      const code = params.get("code"); if (!code) throw new Error("Missing OAuth Authorization Code.");
      const server = await this.serverFactory.fromIssuer(stored.iss, stored.authMethod, stored.dpopKey);
      const issuer = params.get("iss");
      if ((issuer !== null && (!server.issuer || issuer !== server.issuer)) || (issuer === null && server.serverMetadata.authorization_response_iss_parameter_supported)) throw new Error("OAuth Issuer Mismatch Or Missing Issuer.");
      const tokenSet = await server.exchangeCode(code, stored.verifier, options.redirect_uri ?? server.clientMetadata.redirect_uris[0]);
      try {
        const intent = validateBrandLinkIntent(appState, this.primaryDid());
        assertBrandAccountAvailable(intent.ownerDid, tokenSet.sub);
        try { await this.revoke(tokenSet.sub); } catch { /* Same SDK best-effort replacement of a prior brand grant. */ }
        validateBrandLinkIntent(appState, this.primaryDid());
        await this.sessionGetter.setStored(tokenSet.sub, { dpopKey: stored.dpopKey, authMethod: server.authMethod, tokenSet });
        return { session: this.createSession(server, tokenSet.sub), state: appState };
      } catch (error) {
        // Revoke only the new rejected grant, never the owner's existing session.
        await server.revoke(tokenSet.refresh_token || tokenSet.access_token).catch(() => undefined);
        throw error;
      }
    } catch (error) { throw OAuthCallbackError.from(error, params, appState); }
  }
}
