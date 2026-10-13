-- How long a call took, in milliseconds.
--
-- Null where there is nothing to say: a call stored before this column existed,
-- one the user rejected, or one still running.
ALTER TABLE tool_call ADD COLUMN elapsed_ms INTEGER;
