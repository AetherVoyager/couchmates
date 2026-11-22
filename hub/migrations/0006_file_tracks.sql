-- Each video file's audio, subtitle and video tracks, as the first app to
-- read the file found them, so details pages show them at once for everyone.
-- `key_hash` is the SHA-256 (hex) of the app's file key: the file's size and
-- name, which are the same for every user.
CREATE TABLE file_tracks (
  key_hash TEXT PRIMARY KEY,
  tracks TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
