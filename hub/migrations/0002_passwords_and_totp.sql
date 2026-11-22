-- App users sign in with a username and password instead of one-time codes.
DROP TABLE IF EXISTS invites;
ALTER TABLE users ADD COLUMN username TEXT;
ALTER TABLE users ADD COLUMN password_hash TEXT;
CREATE UNIQUE INDEX idx_users_username ON users (username);

-- Admin sessions only count once the authenticator code was checked.
ALTER TABLE admin_sessions ADD COLUMN mfa_ok INTEGER NOT NULL DEFAULT 0;
