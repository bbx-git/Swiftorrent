# 0008: No traces of what was downloaded

## Context
`URLSession.shared` wrote every tracker announce (URL with the info-hash), `.torrent` fetch and web-seed reply to `~/Library/Caches/app.swiftorrent.client/Cache.db`, plus cookies and HSTS/alt-svc state under `~/Library/HTTPStorages/`. Logger calls printed torrent names and paths as `.public`, so they were kept in the unified log. Alternatives: clear the cache on quit (a crash leaves it), set `URLCache.shared` to zero size (cookies and HTTP storage still written), or a dedicated ephemeral session.

## Decision
- All HTTP goes through `URLSession.traceless`: ephemeral, with no cache, cookie store or credential store. Every Core initializer defaults to it (test `TracelessHTTPTests`).
- Torrent names, file paths and error texts that contain them are logged `.private`.
- The only thing that persists besides the downloaded files is `session.json`, the resume list, which drops a torrent's row when the torrent is removed.

## Consequences
- No HTTP cache between launches; trackers and web seeds are hit fresh (they never sent cacheable replies worth keeping).
- Things the app does not control: macOS remembers the open panel's last folder (`NSOSPLastRootDirectory` in the app's preferences) and window frames; Spotlight indexes the destination folder like any other.
- Anything added later that writes to disk (a log file, a cache, a thumbnail) must keep to this rule.
