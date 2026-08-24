CREATE TABLE attachment (
  message_id INTEGER NOT NULL REFERENCES message(id) ON DELETE CASCADE,
  seq        INTEGER NOT NULL,
  path       TEXT    NOT NULL,
  body       TEXT    NOT NULL,
  PRIMARY KEY (message_id, seq)
) WITHOUT ROWID;
