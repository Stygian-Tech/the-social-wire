package listcore

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"time"

	"golang.org/x/text/collate"
	"golang.org/x/text/language"
)

var ErrInvalidInput = errors.New("invalid Standard Reader list input")
var ErrNotFound = errors.New("Standard Reader list not found")

func Load(ctx context.Context, reader Reader, viewer string) (Response, error) {
	type readResult struct {
		read RecordRead
		err  error
	}
	reads := make(chan readResult, 1)
	go func() { read, err := reader.Records(ctx, viewer, Collection); reads <- readResult{read, err} }()
	saves, saveErr := reader.Records(ctx, viewer, SaveCollection)
	own := <-reads
	if own.err != nil {
		return Response{}, own.err
	}
	if saveErr != nil {
		return Response{}, saveErr
	}
	saved := map[string]bool{}
	for _, record := range saves.Records {
		var uri string
		if json.Unmarshal(record.Value["list"], &uri) == nil {
			if _, ok := ParseIdentity(uri); ok {
				saved[uri] = true
			}
		}
	}
	byURI := map[string]List{}
	for _, record := range own.read.Records {
		identity, ok := ParseIdentity(record.URI)
		if !ok || identity.DID != viewer {
			continue
		}
		data, err := json.Marshal(record.Value)
		if err != nil {
			continue
		}
		list, err := Decode(data, identity, viewer, saved[identity.URI()])
		if err == nil && list != nil {
			byURI[list.URI] = *list
		}
	}
	complete := own.read.Complete && saves.Complete && len(saved) <= 200
	unresolved := []string{}
	for uri := range saved {
		if _, exists := byURI[uri]; !exists {
			unresolved = append(unresolved, uri)
		}
	}
	sort.Strings(unresolved)
	if len(unresolved) > 200 {
		unresolved = unresolved[:200]
	}
	for start := 0; start < len(unresolved); start += 5 {
		end := min(start+5, len(unresolved))
		results := make(chan *List, end-start)
		for _, uri := range unresolved[start:end] {
			go func() { list, _ := Resolve(ctx, reader, uri, viewer, true); results <- list }()
		}
		for range end - start {
			list := <-results
			if list == nil {
				complete = false
			} else {
				byURI[list.URI] = *list
			}
		}
	}
	lists := []List{}
	for _, list := range byURI {
		lists = append(lists, list)
	}
	return response(lists, complete), nil
}

func Resolve(ctx context.Context, reader Reader, input, viewer string, saved bool) (*List, error) {
	identity, ok := ParseResolutionInput(input)
	if !ok {
		return nil, ErrInvalidInput
	}
	data, err := reader.Record(ctx, identity)
	if err != nil {
		return nil, err
	}
	if data == nil {
		return nil, ErrNotFound
	}
	list, err := Decode(data, identity, viewer, saved)
	if err != nil || list == nil {
		return nil, ErrNotFound
	}
	return list, nil
}

func Search(ctx context.Context, reader Reader, creator, viewer string, saved map[string]bool) (Response, error) {
	input := strings.TrimSpace(creator)
	if input == "" || len([]rune(input)) > 253 || strings.ContainsAny(input, "/?") {
		return Response{}, ErrInvalidInput
	}
	did, err := reader.CreatorDID(ctx, input)
	if err != nil {
		return Response{}, err
	}
	if did == "" {
		return Response{}, ErrNotFound
	}
	records, err := reader.Records(ctx, did, Collection)
	if err != nil {
		return Response{}, err
	}
	lists := []List{}
	for _, record := range records.Records {
		identity, ok := ParseIdentity(record.URI)
		if !ok || identity.DID != did {
			continue
		}
		data, err := json.Marshal(record.Value)
		if err != nil {
			continue
		}
		if list, err := Decode(data, identity, viewer, saved[identity.URI()]); err == nil && list != nil {
			lists = append(lists, *list)
		}
	}
	result := response(lists, records.Complete)
	result.CreatorDID = &did
	return result, nil
}

func response(lists []List, complete bool) Response {
	comparator := collate.New(language.English, collate.Numeric)
	sort.SliceStable(lists, func(i, j int) bool {
		if lists[i].Owned != lists[j].Owned {
			return lists[i].Owned
		}
		comparison := comparator.CompareString(lists[i].Name, lists[j].Name)
		if comparison == 0 {
			return lists[i].URI < lists[j].URI
		}
		return comparison < 0
	})
	return Response{Lists: lists, Complete: complete, RefreshedAt: time.Now().UTC().Format(time.RFC3339)}
}
