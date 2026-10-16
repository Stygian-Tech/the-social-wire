package publicationcore

import (
	"context"
	"sync"
)

// Unread publications are independent cache keys. Bound in-flight commands and
// join all workers so a large sidebar costs batches of round trips, without
// leaving cache work behind after its request is canceled.
func parallelUnreadCache(ctx context.Context, count int, run func(int) error) error {
	jobs := make(chan int)
	errors := make(chan error, 1)
	var workers sync.WaitGroup
	for worker := 0; worker < min(count, 8); worker++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for i := range jobs {
				if ctx.Err() != nil {
					continue
				}
				if err := run(i); err != nil {
					select {
					case errors <- err:
					default:
					}
				}
			}
		}()
	}
	for i := 0; i < count; i++ {
		if ctx.Err() != nil {
			break
		}
		jobs <- i
	}
	close(jobs)
	workers.Wait()
	if err := ctx.Err(); err != nil {
		return err
	}
	select {
	case err := <-errors:
		return err
	default:
		return nil
	}
}
