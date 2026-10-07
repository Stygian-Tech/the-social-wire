package gatewaycore

import (
	"context"
	"encoding/json"
	"golang.org/x/sync/singleflight"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

type NonceChallenge struct{ Nonce string }

func (e NonceChallenge) Error() string { return "PDS DPoP nonce challenge" }

type AttestationOutcome struct {
	Token     AccessToken
	Nonce     string
	ExpiresAt time.Time
}
type PDSAttestor struct {
	Verifier *TokenVerifier
	mu       sync.Mutex
	cache    map[string]AttestationOutcome
	inFlight int
	origins  map[string]int
	group    singleflight.Group
}

func (a *PDSAttestor) Attest(ctx context.Context, token, authorization, sessionProof string, gateway VerifiedDPoP, now time.Time) (AttestationOutcome, error) {
	candidate, e := DecodeAccessCandidate(token, now)
	if e != nil || !strings.HasPrefix(candidate.DID, "did:plc:") || candidate.JKT != gateway.Thumbprint {
		return AttestationOutcome{}, ErrAuthentication
	}
	key := AccessTokenATH(token + ":" + gateway.Thumbprint)
	a.mu.Lock()
	cached, ok := a.cache[key]
	a.mu.Unlock()
	if ok && cached.ExpiresAt.After(now) {
		cached.Nonce = ""
		return cached, nil
	}
	if sessionProof == "" || len(sessionProof) > 8192 || strings.Contains(sessionProof, ",") {
		return AttestationOutcome{}, ErrAuthentication
	}
	ch := a.group.DoChan(key, func() (any, error) {
		a.mu.Lock()
		if a.inFlight >= 64 {
			a.mu.Unlock()
			return nil, ErrAuthDependency
		}
		a.inFlight++
		a.mu.Unlock()
		defer func() { a.mu.Lock(); a.inFlight--; a.mu.Unlock() }()
		work, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		authority, e := a.Verifier.resolveAuthorityMode(work, candidate.DID, true)
		if e != nil {
			return nil, e
		}
		issuer, e := NormalizePublicRemoteBase(candidate.Issuer)
		trusted := false
		for _, server := range authority.AuthorizationServers {
			trusted = trusted || server == issuer
		}
		if e != nil || !trusted {
			return nil, ErrAuthentication
		}
		a.mu.Lock()
		if a.origins == nil {
			a.origins = map[string]int{}
		}
		if a.origins[authority.PDS] >= 8 {
			a.mu.Unlock()
			return nil, ErrAuthDependency
		}
		a.origins[authority.PDS]++
		a.mu.Unlock()
		defer func() { a.mu.Lock(); a.origins[authority.PDS]--; a.mu.Unlock() }()
		target := authority.PDS + "/xrpc/com.atproto.server.getSession"
		session, e := VerifyDPoP(sessionProof, "GET", target, token, candidate.JKT, time.Now())
		if e != nil || session.Thumbprint != gateway.Thumbprint {
			return nil, ErrAuthentication
		}
		request, cancel := context.WithTimeout(work, 10*time.Second)
		defer cancel()
		r, e := http.NewRequestWithContext(request, "GET", target, nil)
		if e != nil {
			return nil, e
		}
		r.Header.Set("Accept", "application/json")
		r.Header.Set("Authorization", authorization)
		r.Header.Set("DPoP", sessionProof)
		resp, e := a.Verifier.Client.Do(r)
		if e != nil {
			return nil, ErrAuthDependency
		}
		defer resp.Body.Close()
		nonce := strings.TrimSpace(resp.Header.Get("DPoP-Nonce"))
		if len(nonce) > 1024 {
			nonce = ""
		}
		if (resp.StatusCode == 400 || resp.StatusCode == 401) && nonce != "" {
			return nil, NonceChallenge{nonce}
		}
		if resp.StatusCode == 429 || resp.StatusCode >= 500 {
			return nil, ErrAuthDependency
		}
		if resp.StatusCode != 200 {
			return nil, ErrAuthentication
		}
		raw, e := io.ReadAll(io.LimitReader(resp.Body, 65537))
		if e != nil {
			return nil, ErrAuthDependency
		}
		if len(raw) > 65536 {
			return nil, ErrAuthentication
		}
		var response struct {
			DID    string `json:"did"`
			Active *bool  `json:"active"`
		}
		if json.Unmarshal(raw, &response) != nil || response.DID != candidate.DID || (response.Active != nil && !*response.Active) {
			return nil, ErrAuthentication
		}
		expiry := now.Add(60 * time.Second)
		if candidate.ExpiresAt.Before(expiry) {
			expiry = candidate.ExpiresAt
		}
		out := AttestationOutcome{candidate, nonce, expiry}
		a.mu.Lock()
		defer a.mu.Unlock()
		if a.cache == nil {
			a.cache = map[string]AttestationOutcome{}
		}
		for k, entry := range a.cache {
			if !entry.ExpiresAt.After(time.Now()) {
				delete(a.cache, k)
			}
		}
		if len(a.cache) >= 10000 {
			var oldest string
			var oldestTime time.Time
			for k, entry := range a.cache {
				if oldest == "" || entry.ExpiresAt.Before(oldestTime) {
					oldest = k
					oldestTime = entry.ExpiresAt
				}
			}
			delete(a.cache, oldest)
		}
		a.cache[key] = out
		return out, nil
	})
	select {
	case <-ctx.Done():
		return AttestationOutcome{}, ctx.Err()
	case result := <-ch:
		if result.Err != nil {
			return AttestationOutcome{}, result.Err
		}
		return result.Val.(AttestationOutcome), nil
	}
}

var _ error = NonceChallenge{}
