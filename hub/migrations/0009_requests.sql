-- Titles friends asked the admin to add (the app's search: Request). One row
-- per title; `media_request_users` lists who asked. Only the admin changes
-- `status` (pending, approved, added, declined) on the Requests page. Nothing
-- is downloaded: the admin adds the title to Telegram-Stremio by hand.
CREATE TABLE media_requests (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  title_id TEXT NOT NULL,
  name TEXT NOT NULL,
  year TEXT,
  poster TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  note TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE (kind, title_id)
);
CREATE INDEX idx_media_requests_status ON media_requests (status, updated_at);

CREATE TABLE media_request_users (
  request_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (request_id, user_id)
);
CREATE INDEX idx_media_request_users_user ON media_request_users (user_id);
