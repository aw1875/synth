-- What a file held before synth's own tools first changed it in a turn, so the
-- turn can be undone. `seq` is the prompt that began the turn; `content` is null
-- where the file did not exist yet. `after_hash` is what the tools left behind,
-- to tell whether someone changed the file since.
CREATE TABLE checkpoint (
  session_id INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  seq        INTEGER NOT NULL,
  path       TEXT    NOT NULL,
  content    BLOB,
  after_hash INTEGER,
  PRIMARY KEY (session_id, seq, path)
) WITHOUT ROWID;
