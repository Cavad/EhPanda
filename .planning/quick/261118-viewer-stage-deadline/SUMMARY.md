# Viewer-stage deadline for page attempts — 2026-11-18 (build 168)

Continuation of the build 163–167 download-reliability work (handover "EhPanda download handover
through build 167"). The owner's iPhone still showed a gallery stuck at N-1 of N with the green
badge (most recently 142/143). Builds 166 and 167 made no reported difference. No device log or
gallery link was available.

## Finding

Every page attempt begins with a viewer request: the `s/` page, the MPV `imagedispatch` call, or
the direct-delivery retry. Through build 167 that request had no deadline owned by the app. It relied
only on the URLRequest `timeoutInterval` of 20 s (30 s on the recovery session). URLSession treats
that interval as idle time reset by every packet, and enforces it only for loads it performs
itself. A custom `URLProtocol` owns its own timeouts. The Laboratory "Bypass SNI filtering" option
registers `DFURLProtocol` for the shared session. That protocol has no timeout, and its stream
handler reported nothing when a stream failed with a nil `streamError`. The 60 s byte-idle watchdog
covers only the image transfer, and it never starts while the viewer stage is pending. A viewer
load that never answered therefore held its page forever. With the 20-second second slot, the
other pages finished around it, which leaves the reported N-1 of N with the active badge.

The 20-second second-slot condition, the image watchdog and peer recovery are unchanged.

## Change

- `DownloadClient+PageStageDeadline.swift`: `withPageStageDeadline(seconds:clock:operation:)`
  fails with the retryable `AppError.networkingFailed` after 30 s, or 40 s on the recovery
  session. It returns at the deadline even if the load ignores cancellation, and a caller's
  cancellation still reads as `CancellationError`.
- It is applied to the normal viewer and MPV dispatch requests in `resolvedImageSource`, and to the
  direct-delivery viewer request in `resolveMainSiteImage`. A missed deadline sets
  `retryingViewerConnection`, so the next attempt uses the separate native recovery session, which
  is not routed through `DFURLProtocol`.
- `DFStreamHandler`: a stream error without an error object now reports
  `URLError(.networkConnectionLost)`. A rejected certificate now stops the load instead of going
  on to deliver the body.
- `GalleryMPVImageURLRequest` is declared `Sendable`. Its stored properties already were.
- Test: `DownloadViewerDeadlineTests` covers a viewer load that never answers, for both normal and
  MPV sources, with failover to the recovery session on a test clock. It also checks the deadline
  against an operation that ignores cancellation (held on a gate the case opens afterwards), a
  pass-through result and caller cancellation.

## Verification

- Run 44297758579 archived build 168 (unsigned) successfully. In the focused download regressions,
  41 of 43 tests passed, including every existing `DownloadImageParsingTests`,
  `DownloadPageTransferProgressTests` and `ImageRequestBaselineTests` case. The two failures were
  wall-clock bounds in the new suite (10.5 s against 10 s; 7.6 s against 4 s) on the parallel
  simulator. Every functional expectation held. Those bounds were replaced by the gate and the
  test clock, the repository's own practice for timing.
- `build-personal-ipa.yml` also runs from `claude/vibrant-mayer-3l48ge`, archives build 168 and adds the
  new suite to the focused download regressions.

## Live probe (container route, signed-in test account)

ExHentai gallery 4337987 has 147 pages. A script followed the app's sequence (viewer, image URL,
streamed transfer, then the `nl` reload on failure) with two workers. All 147 pages arrived in
127 s. The first attempt failed for 15 pages. Each of those first attempts went to an H@H peer on
a port other than 443 and was reset after about 2 s. This environment's egress proxy refuses ports
other than 443, so these resets do not show peer health. The reload put each of the 15 pages on a
port-443 peer, and the transfer finished in less than 1.5 s. On this route, peer recovery works. The
route cannot reproduce the iPhone's network, and the probe did not run the app.

## Open

- Whether the owner's iPhone has "Bypass SNI filtering" enabled is unconfirmed. The deadline helps
  either way. With the option on, the hang this change removes is a complete explanation for the
  symptom. With it off, the cause remains unconfirmed.
- Green covers both Downloading and Queued, so the badge alone cannot tell a running page from a
  queued gallery. The inspector's status text distinguishes them.
