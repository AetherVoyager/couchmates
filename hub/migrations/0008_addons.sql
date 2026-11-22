-- Public Stremio add-ons the admin added on the Add-ons page. Apps get the
-- enabled ones in their config and call them directly, after Telegram-Stremio.
-- `url_enc` is the manifest URL, sealed with HUB_SECRET because configured
-- add-ons carry keys in it; `url_hash` (SHA-256 hex) stops duplicates.
-- `manifest` and `report` are JSON: the manifest as last read, and the
-- compatibility check (hub/core/src/addons.rs).
CREATE TABLE addons (
  id TEXT PRIMARY KEY,
  url_enc TEXT NOT NULL,
  url_hash TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  position INTEGER NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  manifest TEXT NOT NULL,
  report TEXT NOT NULL,
  checked_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
