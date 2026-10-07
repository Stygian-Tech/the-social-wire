package wireworkercore

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"

	"golang.org/x/sync/errgroup"
)

type TalkedProfile struct {
	DID         string  `json:"did"`
	Handle      string  `json:"handle"`
	DisplayName *string `json:"displayName"`
	Avatar      *string `json:"avatar"`
	Description *string `json:"description"`
	Labels      []struct {
		Value string `json:"val"`
	} `json:"labels"`
}

func (h *EnrichmentHost) profileBatch(ctx context.Context, at time.Time) (int, error) {
	rows, err := h.DB.QueryContext(ctx, profileClaimSQL, at, max(1, min(h.Config.MetadataBatch, 100)), at.Add(300*time.Second))
	if err != nil {
		return 0, err
	}
	var dids []string
	for rows.Next() {
		var did string
		if err := rows.Scan(&did); err != nil {
			rows.Close()
			return 0, err
		}
		dids = append(dids, did)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return 0, err
	}
	group, ctx := errgroup.WithContext(ctx)
	group.SetLimit(max(1, h.Config.MetadataConcurrency))
	for _, did := range dids {
		did := did
		group.Go(func() error {
			profile, fetchErr := h.fetchProfile(ctx, did)
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if fetchErr != nil {
				_, err := h.DB.ExecContext(ctx, profileFailureSQL, at, at.Add(time.Hour), did)
				return err
			}
			_, err := h.DB.ExecContext(ctx, profileStoreSQL, profile.DID, profile.Handle, profile.DisplayName, profile.Avatar, profile.Description, at, at.Add(24*time.Hour))
			return err
		})
	}
	return len(dids), group.Wait()
}
func (h *EnrichmentHost) fetchProfile(ctx context.Context, did string) (*TalkedProfile, error) {
	if !strings.HasPrefix(did, "did:") {
		return nil, errors.New("invalid profile DID")
	}
	requestCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	status, _, data, err := h.ProfileHTTP.Get(requestCtx, "https://public.api.bsky.app/xrpc/app.bsky.actor.getProfile?"+url.Values{"actor": {did}}.Encode(), http.Header{"Accept": {"application/json"}, "User-Agent": {"TheSocialWire-WirePeople/1"}}, 64*1024, 0)
	if err != nil {
		return nil, err
	}
	if status != 200 {
		return nil, errors.New("profile response unavailable")
	}
	var profile TalkedProfile
	if json.Unmarshal(data, &profile) != nil || !strings.EqualFold(profile.DID, did) || profile.Handle == "" {
		return nil, errors.New("profile identity mismatch")
	}
	for _, label := range profile.Labels {
		switch strings.ToLower(label.Value) {
		case "adult", "porn", "sexual", "graphic-media", "spam", "impersonation":
			return nil, errors.New("moderated profile")
		}
	}
	profile.DID = strings.ToLower(profile.DID)
	return &profile, nil
}
