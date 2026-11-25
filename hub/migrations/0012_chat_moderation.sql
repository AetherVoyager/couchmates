-- Chat moderation. Chat admins get a verified badge and may delete anyone's
-- public messages and mute people. A muted user can't send messages until
-- `chat_muted_until` (Unix seconds); 253402300799 means until lifted.
ALTER TABLE users ADD COLUMN chat_admin INTEGER NOT NULL DEFAULT 0;
ALTER TABLE users ADD COLUMN chat_muted_until INTEGER;

-- The owner's own account starts as the chat admin.
UPDATE users SET chat_admin = 1 WHERE lower(username) = 'ajesh' OR (username IS NULL AND lower(name) = 'ajesh');
