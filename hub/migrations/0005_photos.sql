-- Profile pictures, small enough (≤ 300 KB, usually ~30 KB) to keep in D1
-- as base64. `version` is the Unix time of the upload; it goes in the photo's
-- URL so apps can cache each picture for good.
CREATE TABLE photos (
  user_id TEXT PRIMARY KEY,
  mime TEXT NOT NULL,
  data TEXT NOT NULL,
  version INTEGER NOT NULL
);
