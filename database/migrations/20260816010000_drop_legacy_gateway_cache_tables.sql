-- Gateway no longer serves the legacy discovery or entry content paths.
-- User-owned PDS record caching remains in pds_repo_record_cache.
DROP TABLE IF EXISTS public.discovery_cache;
DROP TABLE IF EXISTS public.entry_cache;
