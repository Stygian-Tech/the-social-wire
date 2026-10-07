package publicationcore

import (
	"context"
	"errors"
)

func (s *Service) Invalidate(ctx context.Context, viewer string, publications []string) error {
	if s.Cache == nil {
		return nil
	}
	errs := []error{s.Cache.Projection.InvalidateViewer(ctx, viewer)}
	for _, id := range publications {
		errs = append(errs, s.Cache.Projection.InvalidatePublication(ctx, id))
	}
	return errors.Join(errs...)
}
