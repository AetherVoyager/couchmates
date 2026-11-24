-- The address each device last reported its presence from, for the admin's
-- Tracearr (through the Hub's Jellyfin-style API).
ALTER TABLE presence ADD COLUMN ip TEXT;
