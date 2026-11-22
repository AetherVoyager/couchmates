-- The app's chat: one public channel for everyone, and private chats between
-- two people (`dm:<user id>:<user id>`, ids sorted). Kept for good; a user's
-- private chats go when the user is deleted.
CREATE TABLE chat_messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  channel TEXT NOT NULL,
  sender TEXT NOT NULL,
  -- The other person in a private chat; null on the public channel.
  recipient TEXT,
  text TEXT NOT NULL,
  sent_at INTEGER NOT NULL
);
CREATE INDEX idx_chat_channel ON chat_messages (channel, id);
CREATE INDEX idx_chat_sender ON chat_messages (sender, channel);
CREATE INDEX idx_chat_recipient ON chat_messages (recipient, channel);

-- How far each user has read each channel.
CREATE TABLE chat_reads (
  user_id TEXT NOT NULL,
  channel TEXT NOT NULL,
  last_read INTEGER NOT NULL,
  PRIMARY KEY (user_id, channel)
);
