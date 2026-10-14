# Clear completed torrents

## Goal
A "Clear Completed" button removes every finished torrent from the list (files stay on disk). It is enabled only when every torrent in the list is complete.

## Steps
- [ ] Failing Domain test: `session.removeCompleted()` removes all items and keeps their files; `session.canClearCompleted` is false for an empty list or when any item is not complete, true when all are.
- [ ] Add `canClearCompleted` and `removeCompleted()` to `TorrentSession`, reusing the existing remove-without-delete path.
- [ ] Add the button to the window header, disabled unless `canClearCompleted`.
- [ ] Test, build, deploy; check by hand.

## Done when
- Domain tests pass; existing suites stay green.
- By hand: button greyed while anything downloads/paused/failed, active when all say Complete; clicking empties the list and leaves files in the download folder.
