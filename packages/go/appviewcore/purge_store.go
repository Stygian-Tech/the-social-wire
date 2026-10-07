package appviewcore

import "context"

// Purge preserves legacy floors while deleting explicit viewer read state.
func (s ReadMutationStore) Purge(ctx context.Context, viewer string) error {
	tx, err := beginLegacyMutation(ctx, s.DB, viewer)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, table := range []string{"read_marks", "appview_unread_overrides"} {
		if _, err := tx.ExecContext(ctx, "DELETE FROM "+table+" WHERE viewer_did=$1", viewer); err != nil {
			return err
		}
	}
	return tx.Commit()
}
