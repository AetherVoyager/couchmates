-- A device that said it's closing or signing out is offline at once, while its
-- last report time still says when it was last seen.
ALTER TABLE presence ADD COLUMN offline INTEGER NOT NULL DEFAULT 0;
