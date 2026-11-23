-- Requests for single episodes of a show. `slot` is '' for a movie or a whole
-- show, or 'season:episode' for one episode, so the same title can be asked
-- for one episode at a time. SQLite can't change a UNIQUE constraint, so the
-- table is rebuilt; `media_request_users` refers to requests by id and stays.
CREATE TABLE media_requests_new (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  title_id TEXT NOT NULL,
  name TEXT NOT NULL,
  year TEXT,
  poster TEXT,
  season INTEGER,
  episode INTEGER,
  episode_title TEXT,
  slot TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'pending',
  note TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE (kind, title_id, slot)
);
INSERT INTO media_requests_new (id, kind, title_id, name, year, poster, status, note, created_at, updated_at)
  SELECT id, kind, title_id, name, year, poster, status, note, created_at, updated_at FROM media_requests;
DROP TABLE media_requests;
ALTER TABLE media_requests_new RENAME TO media_requests;
CREATE INDEX idx_media_requests_status ON media_requests (status, updated_at);
CREATE INDEX idx_media_requests_title ON media_requests (title_id);
