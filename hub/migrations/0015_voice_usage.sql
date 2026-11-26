-- Voice usage for the Voice page.
--
-- relay_days: one row per UTC day from the relay monitor on the coturn VM
-- (hub/dev/relay-agent). The agent sends running totals for the day, so a
-- report replaces the row's figures when they are larger.
CREATE TABLE relay_days (
  day TEXT PRIMARY KEY,          -- YYYY-MM-DD (UTC)
  sessions INTEGER NOT NULL,     -- relay allocations that started
  minutes REAL NOT NULL,         -- minutes someone's audio went through the relay
  bytes_in REAL NOT NULL,
  bytes_out REAL NOT NULL,
  updated_at INTEGER NOT NULL
);

-- livekit_sessions: one row per participant connection, from LiveKit's
-- participant_joined / participant_left webhooks.
CREATE TABLE livekit_sessions (
  sid TEXT PRIMARY KEY,          -- LiveKit's participant sid (PA_...)
  room TEXT NOT NULL,
  identity TEXT NOT NULL,
  joined_at INTEGER NOT NULL,
  left_at INTEGER
);
CREATE INDEX idx_livekit_sessions_joined ON livekit_sessions (joined_at);
