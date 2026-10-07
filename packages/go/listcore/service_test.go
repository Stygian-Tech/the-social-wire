package listcore

import (
	"context"
	"encoding/json"
	"sync/atomic"
	"testing"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
)

type orderedReader struct {
	fixtureReader
	calls    atomic.Int32
	started  chan int
	releases []chan struct{}
}

func (r *orderedReader) Records(ctx context.Context, did, collection string) (RecordRead, error) {
	if collection == SaveCollection {
		return RecordRead{Records: []gatewaycore.RepoRecord{}, Complete: true}, nil
	}
	index := int(r.calls.Add(1) - 1)
	r.started <- index
	select {
	case <-ctx.Done():
		return RecordRead{}, ctx.Err()
	case <-r.releases[index]:
	}
	name := "Older"
	if index == 1 {
		name = "Newer"
	}
	var value map[string]json.RawMessage
	json.Unmarshal(fixtureList(name), &value)
	return RecordRead{Records: []gatewaycore.RepoRecord{{URI: Identity{did, "list"}.URI(), Value: value}}, Complete: true}, nil
}
func TestRefreshCannotBeOverwrittenByEarlierConcurrentLoad(t *testing.T) {
	reader := &orderedReader{started: make(chan int, 2), releases: []chan struct{}{make(chan struct{}), make(chan struct{})}}
	service := Service{Reader: reader}
	type outcome struct {
		response Response
		err      error
	}
	old := make(chan outcome, 1)
	go func() {
		response, err := service.Lists(context.Background(), "did:plc:viewer", false)
		old <- outcome{response, err}
	}()
	if index := <-reader.started; index != 0 {
		t.Fatalf("first load index %d", index)
	}
	newer := make(chan outcome, 1)
	go func() {
		response, err := service.Lists(context.Background(), "did:plc:viewer", true)
		newer <- outcome{response, err}
	}()
	if index := <-reader.started; index != 1 {
		t.Fatalf("refresh index %d", index)
	}
	close(reader.releases[1])
	fresh := <-newer
	if fresh.err != nil || fresh.response.Lists[0].Name != "Newer" {
		t.Fatalf("refresh: %#v", fresh)
	}
	close(reader.releases[0])
	prior := <-old
	if prior.err != nil || prior.response.Lists[0].Name != "Older" {
		t.Fatalf("prior: %#v", prior)
	}
	fresh.response.Lists[0].Name = "Caller Mutation"
	result, err := service.Lists(context.Background(), "did:plc:viewer", false)
	if err != nil || result.Lists[0].Name != "Newer" || reader.calls.Load() != 2 {
		t.Fatalf("stale load or caller replaced cache: %#v %v", result, err)
	}
}
