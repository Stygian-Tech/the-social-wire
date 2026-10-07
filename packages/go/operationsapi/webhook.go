package operationsapi

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"time"
)

var ErrWebhookRejected = errors.New("Operations alert webhook rejected")

type WebhookDelivery struct {
	URL, Secret string
	Client      *http.Client
}

func (d WebhookDelivery) Deliver(ctx context.Context, alert any) error {
	body, err := marshalStored(alert)
	if err != nil {
		return err
	}
	mac := hmac.New(sha256.New, []byte(d.Secret))
	mac.Write(body)
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, d.URL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-Social-Wire-Signature", "sha256="+hex.EncodeToString(mac.Sum(nil)))
	client := d.Client
	if client == nil {
		client = http.DefaultClient
	}
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	// Match the existing 64 KiB response bound, rather than draining an unbounded body.
	count, err := io.Copy(io.Discard, io.LimitReader(response.Body, 64*1024+1))
	if err != nil {
		return err
	}
	if count > 64*1024 {
		return errors.New("Operations webhook response exceeded body limit")
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return ErrWebhookRejected
	}
	return nil
}
