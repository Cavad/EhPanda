# EhPanda download stall — handover after build 168

## Status

**Still unresolved on the owner's iPhone.** The owner installed build 168 and reports that the fix
did not work: a gallery still stops one or two pages short of complete (earlier examples were
40/42 and 142/143) and keeps the green badge. Galleries load fully in the browser, and a VPN made
downloads faster and complete. No device log, gallery link or missing page number is available
for any occurrence.

Read first: `AGENTS.md` (project rules), the earlier handover that ends with build 167 (the owner
has it, it is not in this repository), and `SUMMARY.md` in this folder.

## Where the code is

- Branch `claude/vibrant-mayer-3l48ge` on `Cavad/EhPanda`. It is `codex/ipa-3.0.0` (build 167
  source, `1943190`) plus the commits below. The upstream base is the EhPanda `3.0.0` tag, `0b15a14`.
- `60321c7` — the production change and build 168 (`[skip test]`).
- `6d01e25` — test-only correction (`[tests only] [skip test]`).
- This handover and `Scripts/probe-gallery-transfers.py` are in the commit after those.
- IPA: artifact `EhPanda-3.0.0-build168-unsigned` of Actions run
  [44297758579](https://github.com/Cavad/EhPanda/actions/runs/44297758579). It is unsigned and
  retained for 7 days. Its production code equals `6d01e25`.
- Tests: [run 44300701640](https://github.com/Cavad/EhPanda/actions/runs/44300701640) passed all
  43 focused download tests (`DownloadImageParsingTests`, `DownloadPageTransferProgressTests`,
  `DownloadViewerDeadlineTests`, `ImageRequestBaselineTests`). The full FeatureTests plan was not
  run on this branch, because every commit carries `[skip test]`.
- `.github/workflows/build-personal-ipa.yml` now also triggers on `claude/vibrant-mayer-3l48ge`.
  It builds 168, and its focused test job includes `DownloadViewerDeadlineTests`. To build 169,
  bump the number in the four places it appears in that file.

## What build 168 changed

1. **App-owned deadline on the viewer stage** (`DownloadClient+PageStageDeadline.swift`).
   `withPageStageDeadline(seconds:clock:operation:)` races the operation against the injected
   `clock`. At the deadline it throws the retryable `AppError.networkingFailed`. It returns even
   if the operation ignores cancellation: the operation is cancelled and left to finish without
   being awaited. When the caller is cancelled it throws `CancellationError`. The deadline is
   30 s on the normal session and 40 s on the recovery session (`viewerRetrySession`). It wraps:
   - the normal viewer request and the MPV `imagedispatch` request in `resolvedImageSource`
     (`DownloadClient+ExecutionSupport.swift`);
   - the direct-delivery viewer request in `resolveMainSiteImage`
     (`DownloadClient+PageDownloadHelpers.swift`).

   A missed deadline sets `retryingViewerConnection`, so the next attempt runs on the separate
   ephemeral recovery session.
2. **SNI-bypass stream handler** (`NetworkingFeature/DFStreamHandler.swift`). When a stream fails
   without an error object, the handler now reports `URLError(.networkConnectionLost)`; before,
   it reported nothing. After a rejected certificate it now stops the load and returns, where
   before it went on to deliver the body.
3. `GalleryMPVImageURLRequest` is declared `Sendable` (needed to capture it in the deadline closure).
4. Test-only seam: `DownloadCoordinator.testingWithPageStageDeadline` in
   `DownloadClient+Testing.swift`.
5. New suite `DownloadViewerDeadlineTests`:
   - a viewer load that never answers fails over to the recovery session (normal and MPV
     sources);
   - an operation that ignores cancellation, held on a gate the case opens afterwards;
   - a result that passes through, and caller cancellation.

   The first CI run failed two wall-clock assertions under parallel load. They were replaced by
   the gate and the test clock.

Nothing else was changed. These are untouched: the 20 s second-slot rule, the 60 s byte-idle
watchdog, peer reload (`nl`), the direct-delivery last attempt, the background URLSession path
and the manifest rules.

## Why 168 was expected to help, and why it evidently did not

The reasoning behind 168 was this. Every page attempt starts with a viewer request, and before 168
nothing in the app bounded that request. URLSession enforces `timeoutInterval` only for loads it
performs itself; a custom `URLProtocol` owns its own timeouts. The Laboratory option "Bypass SNI
filtering" registers `DFURLProtocol` globally for the shared session, and that protocol has no
timeout. A viewer load hung there would hold its page forever. The other pages would finish
around it under the 20 s second-slot rule, leaving N-1/N with the active badge.

Since 168 did not fix it, the most likely readings are these:

- **That path is not the one stalling.** Either the owner does not use "Bypass SNI filtering"
  (never confirmed), or the viewer stage was never the stuck stage.
- **The page is stuck in the image transfer, not the viewer.** See hypothesis A below.
- **The gallery is not running at all.** Green covers both `.active` (Downloading) and `.queued`
  (`DownloadedGallery+Extensions.swift`: `case .active, .queued: .accentColor`). See hypothesis C.
- **Check first that build 168 is what was tested:** Settings → About shows the build number.

## Ranked hypotheses for the remaining stall

### A. A slow but moving image transfer is never abandoned (most likely)

`watchPageTransfer` and `sweepStarvedPageTransfers` abandon an attempt only after 60 s with no new
bytes (`pageTransferAbandonThreshold`). A transfer that trickles, even a few bytes every few
seconds, is never abandoned however long it runs. This is a recorded owner decision (G-15-2I), and
`aSlowButMovingTransferIsNeverAbandonedUntilItsOwnBytesStop` pins it.

On a route where some H@H peers are throttled or lossy, one page can take many minutes. Two
observations fit: the owner sees completion with a VPN, which changes the route, and the browser
"works", because a user who sees one slow image reloads it or does not notice. The 20 s second-slot
rule then lets every other page finish around the slow one, which is exactly N-1/N with a green
badge. Eventually it may finish, or it may not before the user gives up.

Evidence from the earlier Windows trace (in the 167 handover): 58 of 88 first responses pointed at
peers on ports other than 443 even with "Default port clients only" checked, and 5 of those timed
out before TCP connected. That trace shows dead peers, not trickling ones; a trickle has not been
measured on the owner's route yet.

Possible fixes. Each revises G-15-2I, so ask the owner first:

- **Tail hedge.** When `pending` is empty and one page has been active longer than about 20 s,
  start a second attempt for that page via its reload token (`nl`, a different peer) and keep
  whichever finishes first. This is the best fit to the symptom: it touches only the tail and
  costs one extra request per slow tail page.
- **Throughput floor.** After about 30 s, abandon an attempt whose projected completion (bytes
  per second against `expected`) exceeds a cap such as 3 minutes, then rotate the peer.
- **Hard cap per attempt**, for example 120–180 s, then rotate the peer. Simplest, but it can cut
  off a legitimately large original on cellular.

### B. Dead peers cost 60 s per attempt and up to 4 attempts per page

A peer that drops SYN gets no bytes, so the watchdog fires at 60 s. The next attempt uses the
reload token; it usually yields a port-443 peer, but not always. Worst case is about 4–5 minutes
for one page, after which the page fails and the gallery turns yellow (Needs Attention). This is
bounded, so it explains "slow, then fails" better than "stays green". It is worth shortening if
logs show `Page transfer starved ... abandoned` followed by recovery.

### C. A queued gallery with no run

When green means Queued, the gallery is in the queue but `isSchedulableDownload` is false or
nothing reschedules it. Candidates:

- a scheduling block that is never released (`blockScheduling` / `releaseScheduling` in
  `DownloadClient+Manager.swift` around lines 883–917; used by pause, expiration and folder
  operations). The page loop cancels the run when `schedulingBlockedGalleryCounts[gid] != nil`
  (`DownloadClient+PageDownload.swift` lines 202 and 227);
- the continued-processing expiration pause and the "superseded" path in
  `DownloadClient+Scheduling.swift` `pause(gid:expiration:)`;
- a run that exits via `CancellationError` without a user action, then is rescheduled and loops
  through fetch → restore 142 → retry 143 → cancel.

To distinguish this from A: the inspector's status text says "Downloading" or "Queued", and the
App Activity Logs show whether `Download page attempt failed` and heartbeat lines keep arriving.

### D. The page started while the app was in the background

`rawPageDownloadResponse` uses the background URLSession when `isSceneInBackground` is true.
`waitsForConnectivity = true` is set, and the system retries timed-out background tasks rather
than failing them. The watchdog clock does not run while the process is suspended, so after the
app returns it takes up to 60 s more to abandon the attempt. This is bounded once in the
foreground. It matters if the owner leaves the app (for example to compare in Safari) during the
final pages.

### Ruled out by reading the code

- The page scheduler itself: the 20 s timer, `nextPage` and the event handling cannot deadlock.
- Page-file recognition: the scan is extension-agnostic (`DownloadStore.pageFileScan`).
- The progress push between pages: `ContinuedProcessingSession.updateProgress` is synchronous
  on the main actor.
- `DataCache` lookups: synchronous within its actor.
- Automatic re-queueing after a page failure: `settleDownloadFailure` clears the queue intent.

## What the live probe showed (and did not)

A cloud container ran `Scripts/probe-gallery-transfers.py` with the owner's signed-in test account
against ExHentai gallery 4337987 (147 pages), with two workers. All 147 pages arrived in 127 s.
15 first attempts went to peers on ports other than 443 and were reset after about 2 s. That reset
came from the container's egress proxy, which refuses other ports, so it says nothing about peer
health. Each reload went to a port-443 peer, and that transfer finished in under 1.5 s.

So peer recovery works on a clean route. The probe cannot reproduce the iPhone's network, and it
did not run the app. **Run it from the owner's PC on the same Wi-Fi as the iPhone.** That route is
far closer to the device's. Look at the per-page `ttfb`, `total`, `kbps` and `max_gap` for
trickling or blackholed peers.

```
$env:EH_COOKIE = "ipb_member_id=...; ipb_pass_hash=..."
python Scripts/probe-gallery-transfers.py https://exhentai.org/g/<gid>/<token>/ out.json
```

## Recommended next steps

1. **Get evidence from the device before changing behaviour again.** Five builds (163–168)
   changed behaviour without a device trace. Ask the owner, for the next stuck gallery, for:
   - the gallery link and the missing page number;
   - the inspector status text (Downloading or Queued);
   - Settings → App Activity Logs;
   - whether "Bypass SNI filtering" is on;
   - whether Pause then Resume finishes the gallery.
2. **Add a stuck-page diagnostic first** if the existing logs are not enough. About every 30 s
   while a run is active, log each active page with its current stage (viewer, cache, transfer
   or save), the seconds in that stage, bytes received, expected bytes and the peer port. Follow
   the existing privacy conventions: page numbers and integers public, gid
   `.private(mask: .hash)`, no URLs. One build with this makes the next report conclusive.
3. If the logs show a moving but slow transfer on the last page, implement the tail hedge from
   hypothesis A, after the owner approves revising G-15-2I.
4. If the status is Queued, trace the scheduling-block and expiration-pause paths from hypothesis C.

## Constraints to keep (from AGENTS.md)

- The persisted manifest is the single source of truth for completeness.
- Never delete a gallery folder the run did not create.
- Keep the 20 s condition for opening the second slot.
- Tests run in parallel; isolate clocks and URL stubs per test, and never use `.serialized`.
- Read the root `.swiftlint.yml` first; never suppress a rule.
- Never commit the test account cookies. The probe reads them from `EH_COOKIE` only.
