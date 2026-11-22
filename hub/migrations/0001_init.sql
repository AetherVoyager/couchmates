-- Hub settings. Values for secret keys are AES-GCM encrypted with HUB_SECRET.
CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE admin_sessions (
  token_hash TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);

CREATE TABLE login_attempts (
  ip TEXT NOT NULL,
  at INTEGER NOT NULL
);
CREATE INDEX idx_login_attempts ON login_attempts (ip, at);

-- One app user = one Telegram-Stremio access token.
CREATE TABLE users (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  tgs_token_enc TEXT,
  tgs_token_hash TEXT,
  daily_limit_gb REAL NOT NULL DEFAULT 0,
  monthly_limit_gb REAL NOT NULL DEFAULT 0,
  disabled INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);

-- One-time sign-in codes; only the hash is kept.
CREATE TABLE invites (
  code_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX idx_invites_user ON invites (user_id);

-- Signed-in app devices; the bearer token is stored hashed.
CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL UNIQUE,
  user_id TEXT NOT NULL,
  name TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  last_seen INTEGER NOT NULL
);
CREATE INDEX idx_devices_user ON devices (user_id);

-- Hourly copies of each user's Telegram-Stremio data usage, for charts.
CREATE TABLE usage_snapshots (
  user_id TEXT NOT NULL,
  at INTEGER NOT NULL,
  total_bytes INTEGER NOT NULL,
  PRIMARY KEY (user_id, at)
);
