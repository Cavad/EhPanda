# Rotate slow page transfers and speed up the Downloads index — 2026-11-18 (build 169)

Continuation of `261118-viewer-stage-deadline` (build 168), after the owner reported that 168 did
not help. New owner information: galleries do not only stop one page short. Others stop several
pages short (for example 80 of 83) with the green badge.

## Owner decision

The owner was asked whether to revise G-15-2I (a page transfer is abandoned only after 60 s
without a new byte). The answer added that stalls are not specific to the last page, so the
revision applies to every page rather than the tail only.

## Finding

Every stage of a page attempt was bounded except one: an image transfer that keeps delivering a
few bytes. Its idle time never reaches 60 s, so it is never abandoned and holds its worker
indefinitely. With the default two workers, one such page leaves the gallery at N-1 of N while the
other worker finishes around it, and two such pages stop the run completely with the remaining
pages pending. That is the reported 80/83: two stuck transfers plus one pending page. Dead peers
were bounded, but slowly: 60 s per attempt with no first byte, up to three peer attempts plus the
direct-delivery attempt, so about six minutes before a page failed. A VPN changes the route to the
H@H peers, which matches the owner's observation that downloads then complete.

## Change

- `InFlightPageTransfer.abandonReason(at:)` is the single rule the per-attempt watchdog and the
  heartbeat sweep both apply. For an attempt created in the foreground it abandons when:
  - no first byte arrived within 20 s (`pageTransferFirstByteDeadline`);
  - no byte arrived for 30 s after the first one (`pageTransferAbandonThreshold`, was 60 s);
  - throughput over a 45 s window stayed under 8 KiB/s (`pageTransferMinimumThroughput`). The
    window opens at the first byte and rolls forward whenever a full window passes above the floor.
  An attempt created in the background keeps the original rule, 60 s without bytes
  (`backgroundPageTransferAbandonThreshold`), because the system may defer such a transfer.
- An abandoned attempt still surfaces as the retryable `networkingFailed`, so the page takes the
  peer reload (`nl`), the ordinary dispatch and the direct-delivery attempt it already had.
- The watchdog now wakes every 5 s. Each running attempt logs one line every 30 s, and one line
  when it is abandoned, naming the rule: page, elapsed and idle ms, bytes against expected bytes,
  and the server port. The gid is hash-masked, integers are public, and no URL is logged.
- Downloads index scan: each gallery folder is listed once for both the cover and the pages, not
  twice. The page-file probe drops its separate existence check and asks only the metadata read,
  one filesystem call per file instead of two. A symbolic link is still resolved, so a dangling
  link stays `unprobeable`. The listing is sorted on names read once.
- `fetchDownloads()` runs the first scan when the index is not loaded yet, so a Downloads tab
  opened during launch shows its loading state instead of the empty state, then the list.
- The Downloads view filters the rows once per render rather than four times, and reads emptiness
  off the rows without copying them.
- `build-personal-ipa.yml` builds 169 and runs the whole `DownloadsFeatureTests` target plus
  `ImageRequestBaselineTests`.

## Tests

`DownloadPageTransferProgressTests`: the no-byte case now pins the 20 s first-byte deadline; the
pinned "slow but moving is never abandoned" case is replaced by a trickle that the floor abandons,
a transfer above the floor that runs past many windows, and a background-created attempt that keeps
the 60 s bound. `DownloadLogPrivacyInvariantTests` counts the new hash-masked log line.

## Verification

Not compiled or run locally (Windows host). CI on the build 169 push is the first compile and test.

## Open

- Device evidence is still missing. The new progress and abandonment lines make the next report
  conclusive: they name the stuck page, its stage rule, bytes and port.
- If a stall persists with these lines showing no running transfer, look at the queued-without-run
  path (hypothesis C in `HANDOVER-build-168.md`).
