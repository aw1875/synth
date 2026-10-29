-- The process hosting a live session, one at a time, keyed by handle: a new
-- session has a handle, and a lease, before it has a row.
--
-- A holder renews heartbeat_at while it runs. One that stopped renewing, or
-- whose process is gone, holds nothing.
CREATE TABLE lease (
    public_id    TEXT PRIMARY KEY,
    pid          INTEGER NOT NULL,
    heartbeat_at INTEGER NOT NULL
);
