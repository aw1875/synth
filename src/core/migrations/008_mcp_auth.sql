-- What each MCP server needs to be reached: its OAuth tokens and client
-- registration, a sign-in in flight, and whether it is turned off. One row a
-- server, each written alone, so sessions running side by side change only
-- the server they touched.
--
-- `entry` is a JSON object, shaped as an entry of opencode's `mcp-auth.json`,
-- where these were kept before.
CREATE TABLE mcp_auth (
    name  TEXT PRIMARY KEY,
    entry TEXT NOT NULL
);
