# Curator — agreed product and implementation plan

## Product decisions

A free, native iPhone app for people who take many repeated shots. iOS 27 and Apple Intelligence with on-device vision are required. No account, backend, cloud inference, analytics SDK, or non-AI production fallback. English first; localizable, accessible system UI close to Photos.

The first release finds similar photos within a short shooting sequence across the whole accessible library. It preserves distinct good shots and may suggest multiple keepers. No standalone junk, screenshot, or video cleanup. Include RAW and Live Photos; compare Live Photo motion visually and offer playback with sound, without audio understanding. Rank qualified groups by estimated removable media size. Never choose a keeper by file size or format.

Favourites and edited photos are always protected, including manual overrides. Every group retains at least one photo. Hide uncertain groups. Exclude hidden photos and Shared Albums; public APIs do not identify iCloud Shared Photo Library membership reliably, so do not claim to exclude it.

## Experience

Check model eligibility/readiness before requesting Photos read/write permission. Explain privacy concisely; use real photos immediately, no demo onboarding. Support selected-photo access and its system management UI; distinguish denied, empty, no candidates, model unavailable, paused, and waiting for Wi-Fi states.

Start Scan explicitly. Show results progressively in a native ranked list with thumbnails, date, photo count, estimated size, progress, pause/resume, and basket. Keep the open group stable while the list updates. Grid-first Keep/Remove review, protected/RAW/Live badges, short explanations, full-screen zoom and comparison. Approve each editable group, Keep All, or Decide Later; revisit past decisions. Approved removals accumulate in a basket and can be undone or edited until the single final PhotoKit/system deletion confirmation.

Before deletion, refetch every group member and validate access, content, protection, deletability, and retained photos. Changed groups require review again. Remove whole PHAssets, not individual RAW/JPEG or Live components. Explain iCloud/all-device and Shared Library effects, Photos recovery for 30 days, and that estimated media size is not guaranteed immediately reclaimed device storage. Do not empty Recently Deleted or maintain another photo backup.

Preference controls: Variety (More variations/Balanced/Tighter selection; Balanced), People (Candid/Posed/No preference; No preference), Quality (Moment/Balanced/Sharpness; Balanced). Preserve explicit decisions; refresh unreviewed recommendations after preference changes. Wi-Fi downloads by default; optional cellular. Optional weekly local reminder after the first successful cleanup, opt-in, user-chosen day/time, generic message unless fresh results are known.

## Engineering

SwiftUI, SwiftData, PhotoKit, Vision, FoundationModels, PhotosUI/AVFoundation, BackgroundTasks, UserNotifications. Protocol boundaries for photo access, analysis, scan coordination, and review persistence. Deterministic fixtures only in tests/previews.

Incremental metadata enumeration → burst/temporal candidates → Vision similarity and quality → bounded image comparisons through the on-device model → independent structured-output validation → size estimation → review. Initial temporal bounds: adjacent gaps at most 60 seconds, non-burst span at most 5 minutes. Time alone never proves redundancy. Bounded chunks conservatively retain alternatives across chunk boundaries. Similarity thresholds and prompt/image budgets are provisional until evaluated on real labelled photos.

Use stable per-request attachment labels, no deletion tools, one inference at a time, bounded image loading, off-main image work, and prompt cancellation. Keep metadata, fingerprints, checkpoints and decisions locally; bounded thumbnails, no permanent originals or transcripts. Refusal, invalid output, overflow, missing motion, or unavailable resources cannot produce a partial actionable proposal. Unknown public PHAssetResource.dataSize stays unknown; never fetch originals just to count bytes. Invalidate stale content/versions/preferences, remove inaccessible cached records, checkpoint completed work for termination/resume.

Background work is best effort with native progress and expiration cancellation. Verify FoundationModels background inference on supported hardware before enabling it; generic continued-processing support alone is not proof. Target 100,000-photo libraries and early results; initial scans can take multiple sessions.

## Milestones and release gates

- A: native project, test targets, real multimodal proof, RAW/Live/resource sizing and checkpoint validation. Freeze thresholds and budgets only after measured evaluation.
- B: complete local scan/review/basket/deletion/settings/reminders and lifecycle/accessibility states.
- C: physical iPhone 15 Pro and newer-device validation: latency, memory, thermals, battery, iCloud, background, permissions, deletion and recovery. Simulator is not an iPhone benchmark.
- D: broad TestFlight using the existing developer account, then App Store after safety and usefulness gates. No fixed launch date.

Tests must reject invalid/duplicate/missing model IDs, incomplete decisions, protected removals, stale groups, lost keepers, and unapproved deletions. Cover unknown sizes, compound RAW/Live resources, preference changes, pause/termination/resume, limited/revoked access, and 100k metadata stress. Labelled evaluation includes distinct expressions/compositions, intentional blur, low light, RAW/processed, edits, favourites, and distinct Live motion; all designated preserve cases must pass and coverage must be measured to prevent trivial skip-everything success.

Initial performance target: a useful group within 60 seconds with a ready model and local reference photos; separate download time. Public release requires no critical integrity defects, all safety tests and physical validation. Initial product target: at least 90% acceptance across 1,000 voluntarily judged suggestions from at least 10 beta participants, plus confident and worthwhile cleanup feedback. Optional diagnostic export contains aggregate counts, timings, versions and error categories only; no photos, filenames, asset IDs, locations, prompts or descriptions.
