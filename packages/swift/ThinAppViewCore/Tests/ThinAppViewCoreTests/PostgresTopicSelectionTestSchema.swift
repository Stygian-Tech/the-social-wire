import PostgresNIO

/// Minimal PDS-interest projection tables required by inbox scope checks and selection replay.
/// Keep these aligned with the Finance/Sports feed migrations; serving views are not needed here.
enum PostgresTopicSelectionTestSchema {
  static let statements: [PostgresQuery] = [
    """
    CREATE TABLE IF NOT EXISTS finance_selections (
      viewer_did TEXT NOT NULL, record_key TEXT NOT NULL,
      kind TEXT NOT NULL CHECK (kind IN ('instrument', 'sector')),
      reference TEXT NOT NULL, updated_at TIMESTAMPTZ NOT NULL,
      PRIMARY KEY (viewer_did, record_key)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS finance_selection_sync (
      viewer_did TEXT PRIMARY KEY, synced_at TIMESTAMPTZ NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS finance_selection_versions (
      viewer_did TEXT NOT NULL, record_key TEXT NOT NULL,
      event_at TIMESTAMPTZ NOT NULL, repo_rev TEXT NOT NULL DEFAULT '',
      is_deleted BOOLEAN NOT NULL, PRIMARY KEY (viewer_did, record_key)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS sports_selections (
      viewer_did TEXT NOT NULL, record_key TEXT NOT NULL,
      action TEXT NOT NULL CHECK (action IN ('follow', 'mute')),
      reference TEXT NOT NULL, updated_at TIMESTAMPTZ NOT NULL,
      PRIMARY KEY (viewer_did, record_key)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS sports_selection_sync (
      viewer_did TEXT PRIMARY KEY, synced_at TIMESTAMPTZ NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS sports_selection_versions (
      viewer_did TEXT NOT NULL, record_key TEXT NOT NULL,
      event_at TIMESTAMPTZ NOT NULL, repo_rev TEXT NOT NULL DEFAULT '',
      is_deleted BOOLEAN NOT NULL, PRIMARY KEY (viewer_did, record_key)
    )
    """,
  ]
}
