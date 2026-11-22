-- What each signed-in device is playing, for the app's "who's watching"
-- bubble. One row per device, so an idle laptop doesn't hide the TV that's
-- playing. `watching` is the app's NowWatching JSON, room code included;
-- the code is only ever handed to people whose join request was accepted.
CREATE TABLE presence (
  device_id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  seen_at INTEGER NOT NULL,
  watching TEXT,
  watching_since INTEGER
);
CREATE INDEX idx_presence_user ON presence (user_id);

-- "Can I join?" requests between users.
CREATE TABLE join_requests (
  id TEXT PRIMARY KEY,
  from_user TEXT NOT NULL,
  to_user TEXT NOT NULL,
  title TEXT NOT NULL,
  status TEXT NOT NULL,
  room TEXT,
  created_at INTEGER NOT NULL,
  answered_at INTEGER
);
CREATE INDEX idx_join_requests_from ON join_requests (from_user);
CREATE INDEX idx_join_requests_to ON join_requests (to_user);
