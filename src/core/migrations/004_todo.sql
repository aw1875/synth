CREATE TABLE todo (
  session_id INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  seq        INTEGER NOT NULL,
  text       TEXT    NOT NULL,
  status     TEXT    NOT NULL,
  PRIMARY KEY (session_id, seq)
) WITHOUT ROWID;
