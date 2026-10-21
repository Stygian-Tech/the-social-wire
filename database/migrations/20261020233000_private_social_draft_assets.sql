-- Private canonical attachment store. Owner rows serialize quota, manifests and GC.
CREATE TABLE IF NOT EXISTS private_social_draft_accounts (
 owner TEXT PRIMARY KEY
);
CREATE TABLE IF NOT EXISTS private_social_draft_assets (
 owner TEXT NOT NULL REFERENCES private_social_draft_accounts(owner),
 asset_id UUID NOT NULL,
 metadata BYTEA NOT NULL,
 byte_length BIGINT NOT NULL CHECK (byte_length > 0 AND byte_length <= 104857600),
 object_key TEXT NOT NULL UNIQUE,
 state TEXT NOT NULL CHECK (state IN ('reserved','ready','deleted','purged')),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 PRIMARY KEY(owner, asset_id)
);
CREATE TABLE IF NOT EXISTS private_social_draft_manifests (
 owner TEXT NOT NULL REFERENCES private_social_draft_accounts(owner),
 draft_id TEXT NOT NULL,
 revision BIGINT NOT NULL CHECK(revision > 0),
 deleted BOOLEAN NOT NULL DEFAULT false,
 PRIMARY KEY(owner,draft_id)
);
CREATE TABLE IF NOT EXISTS private_social_draft_bindings (
 owner TEXT NOT NULL,
 draft_id TEXT NOT NULL,
 position INTEGER NOT NULL,
 asset_id UUID NOT NULL,
 role TEXT NOT NULL,
 ref TEXT NOT NULL,
 PRIMARY KEY(owner,draft_id,position),
 FOREIGN KEY(owner,draft_id) REFERENCES private_social_draft_manifests(owner,draft_id),
 FOREIGN KEY(owner,asset_id) REFERENCES private_social_draft_assets(owner,asset_id)
);
CREATE INDEX IF NOT EXISTS private_social_draft_binding_assets ON private_social_draft_bindings(owner,asset_id);
CREATE TABLE IF NOT EXISTS private_social_draft_cleanup (
 owner TEXT NOT NULL,
 asset_id UUID NOT NULL,
 available_at TIMESTAMPTZ NOT NULL DEFAULT now() + interval '24 hours',
 attempts INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY(owner,asset_id),
 FOREIGN KEY(owner,asset_id) REFERENCES private_social_draft_assets(owner,asset_id)
);
CREATE INDEX IF NOT EXISTS private_social_draft_cleanup_due ON private_social_draft_cleanup(available_at,owner,asset_id);
CREATE INDEX IF NOT EXISTS private_social_draft_cleanup_owner_due ON private_social_draft_cleanup(owner,available_at,asset_id);
-- Deleted assets remain charged until S3 deletion is confirmed.
CREATE INDEX IF NOT EXISTS private_social_draft_charged_assets ON private_social_draft_assets(owner) INCLUDE(byte_length) WHERE state<>'purged';
