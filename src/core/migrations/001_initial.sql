CREATE TABLE project (
  id           INTEGER PRIMARY KEY,
  root         TEXT    NOT NULL UNIQUE,
  vcs          TEXT,
  name         TEXT    NOT NULL,
  created_at   INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL
);

CREATE TABLE session (
  id         INTEGER PRIMARY KEY,
  project_id INTEGER NOT NULL REFERENCES project(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  cwd        TEXT    NOT NULL,
  model      TEXT    NOT NULL,
  title      TEXT    NOT NULL DEFAULT '',
  public_id  TEXT    NOT NULL DEFAULT ''
);
CREATE INDEX session_project_updated ON session(project_id, updated_at DESC);
CREATE UNIQUE INDEX session_public_id ON session(public_id)
  WHERE public_id <> '';

CREATE TABLE message (
  id             INTEGER PRIMARY KEY,
  session_id     INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  seq            INTEGER NOT NULL,
  role           TEXT    NOT NULL,
  created_at     INTEGER NOT NULL,
  text           TEXT    NOT NULL DEFAULT '',
  thinking_ms    INTEGER,
  thinking_bytes INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX message_session_seq ON message(session_id, seq);

CREATE TABLE blob (
  message_id INTEGER NOT NULL REFERENCES message(id) ON DELETE CASCADE,
  kind       TEXT    NOT NULL,
  seq        INTEGER NOT NULL,
  body       TEXT    NOT NULL,
  PRIMARY KEY (message_id, kind, seq)
) WITHOUT ROWID;

CREATE TABLE tool_call (
  id           INTEGER PRIMARY KEY,
  message_id   INTEGER NOT NULL REFERENCES message(id) ON DELETE CASCADE,
  seq          INTEGER NOT NULL,
  call_id      TEXT    NOT NULL DEFAULT '',
  name         TEXT    NOT NULL,
  arguments    TEXT    NOT NULL,
  status       TEXT    NOT NULL,
  result       TEXT,
  result_bytes INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX tool_call_message ON tool_call(message_id, seq);

CREATE TABLE read_file (
  session_id INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  path       TEXT    NOT NULL,
  read_at    INTEGER NOT NULL,
  PRIMARY KEY (session_id, path)
) WITHOUT ROWID;

CREATE TABLE approval (
  project_id INTEGER NOT NULL REFERENCES project(id) ON DELETE CASCADE,
  tool       TEXT    NOT NULL,
  pattern    TEXT    NOT NULL,
  PRIMARY KEY (project_id, tool, pattern)
) WITHOUT ROWID;

CREATE TABLE provider (
  id         TEXT    PRIMARY KEY,
  host       TEXT    NOT NULL DEFAULT '',
  updated_at INTEGER NOT NULL
) WITHOUT ROWID;

CREATE TABLE setting (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
) WITHOUT ROWID;

CREATE TRIGGER session_touch AFTER INSERT ON message
BEGIN
  UPDATE session SET updated_at = NEW.created_at WHERE id = NEW.session_id;
END;
