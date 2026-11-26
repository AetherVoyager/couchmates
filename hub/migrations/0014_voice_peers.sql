-- Direct (peer-to-peer) voice: which device is in which voice room. Apps
-- refresh their row every 25 seconds; a row older than 70 seconds has left.
CREATE TABLE voice_peers (
  identity TEXT PRIMARY KEY,
  room TEXT NOT NULL,
  user_id TEXT NOT NULL,
  name TEXT NOT NULL,
  seen_at INTEGER NOT NULL
);
CREATE INDEX idx_voice_peers_room ON voice_peers (room);
