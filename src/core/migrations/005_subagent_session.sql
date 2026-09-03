-- A subagent's transcript is a session like any other, linked back to the tool
-- call that started it. Null for a session a person started.
ALTER TABLE session ADD COLUMN parent_session_id INTEGER REFERENCES session(id) ON DELETE CASCADE;
ALTER TABLE session ADD COLUMN parent_tool_call  INTEGER REFERENCES tool_call(id) ON DELETE CASCADE;

CREATE INDEX session_parent ON session(parent_tool_call) WHERE parent_tool_call IS NOT NULL;
