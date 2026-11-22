-- Trakt and Simkl accounts users link from the app. Tokens are sealed with
-- HUB_SECRET like other secrets.
CREATE TABLE tracker_links (
  user_id TEXT NOT NULL,
  service TEXT NOT NULL,
  access_token_enc TEXT NOT NULL,
  refresh_token_enc TEXT,
  expires_at INTEGER,
  username TEXT,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, service)
);

-- A link in progress: the device code the Hub polls with, never shown to
-- the app.
CREATE TABLE tracker_pending (
  user_id TEXT NOT NULL,
  service TEXT NOT NULL,
  device_code_enc TEXT NOT NULL,
  user_code TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, service)
);
