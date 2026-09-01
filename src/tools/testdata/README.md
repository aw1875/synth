# tools/testdata

Frozen responses that `src/tools` parsers are tested against.

Saved rather than fetched, so the tests stay offline and deterministic. A file
here is a real reply from a real server, captured once and never edited: the
point is that the parser meets the markup as it is actually served, not as we
imagine it.

| file | what it is |
| --- | --- |
| `duckduckgo-results.html` | `GET https://html.duckduckgo.com/html/?q=zig+0.16+std.Io.Writer`, captured 2026-08-28. Ten results, no ads. |

Refresh one only when the site's markup has moved on and the parser has to
change with it, and say so in the commit.
