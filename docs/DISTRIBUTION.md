# Distribution and live testing

## Opening the app on another Mac

`Scripts/build.sh` **ad-hoc signs** the bundle, which is enough to run on the machine
that built it but not to pass Gatekeeper on someone else's Mac. When you copy the
`.app` to another Mac it will be quarantined, so the first launch needs one of:

- **Right-click the app → Open**, then confirm in the dialog (only needed once), or
- strip the quarantine attribute from a terminal:

  ```sh
  xattr -dr com.apple.quarantine /path/to/Swiftorrent.app
  ```

This is normal for unsigned indie Mac apps — the app is fully functional, it just
isn't notarized. To make it launch with **no** prompt on any Mac, the bundle must
be signed with an Apple **Developer ID** certificate and notarized (requires a
paid Apple Developer account). That step can be added to the current
Swift Package build from the command line (`codesign` + `xcrun notarytool` +
`stapler`) — it does **not** require migrating to an Xcode project.

## Live download smoke test

`Fixtures/big-buck-bunny.torrent` is a well-seeded public-domain
torrent kept for end-to-end download testing (real tracker/DHT/peer swarm).
Open it in the packaged app to verify the download path against a live swarm —
e.g. that the peer pool replenishes and the transfer completes and verifies
without seeding. (The unit tests cover parsing/layout/coordinator logic only.)

To exercise the magnet path (info-hash → metadata exchange → swarm), paste this
Big Buck Bunny magnet link into the **Magnet** field:

```text
magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&dn=Big+Buck+Bunny&tr=udp%3A%2F%2Fexplodie.org%3A6969&tr=udp%3A%2F%2Ftracker.coppersurfer.tk%3A6969&tr=udp%3A%2F%2Ftracker.empire-js.us%3A1337&tr=udp%3A%2F%2Ftracker.leechers-paradise.org%3A6969&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337&tr=wss%3A%2F%2Ftracker.btorrent.xyz&tr=wss%3A%2F%2Ftracker.fastcast.nz&tr=wss%3A%2F%2Ftracker.openwebtorrent.com&ws=https%3A%2F%2Fwebtorrent.io%2Ftorrents%2F&xs=https%3A%2F%2Fwebtorrent.io%2Ftorrents%2Fbig-buck-bunny.torrent
```
