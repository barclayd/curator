# Curator

A native iPhone app that helps you review repeated shots and keep the moments you want. All image analysis uses Apple's on-device Foundation Models and Vision frameworks. No account, backend, cloud inference, or analytics SDK.

This is the first development build of the [agreed plan](PLAN.md), **not a validated photo-cleanup release**. The native flow and deterministic safety checks run in Simulator. Real image inference is currently blocked by the development environment; recommendation quality, RAW/Live behaviour and physical-device deletion still need validation.

## Open and run

Open `Curator.xcodeproj`, choose the **Curator** scheme, then an iOS 27 Simulator or eligible iPhone. The checked-in project works without a generator. `project.yml` is its source specification; after adding targets/files, regenerate using the already installed `xcodegen generate` (development tooling only; no third-party app dependencies).

Requirements:

- Xcode 27 with the iOS 27 SDK/runtime.
- iOS 27 and an Apple Intelligence-compatible iPhone for real inference; Apple Intelligence enabled and its models downloaded.
- Simulator model testing also depends on the Mac's model. Use a compatible macOS 27 host; physical-device testing remains necessary.
- For a physical device, choose your existing Apple development team under Signing & Capabilities. No team identifier or credentials are stored here. The initial bundle ID is `com.danbarclay.curator`.

On 13 September 2026 this Mac has **macOS 26.6.2**, **Xcode 27.0 (27A266a)**, and **iOS 27.0 Simulator (24A434)**. The real image probe initially reported unavailable; once capability metadata was ready, the actual image request failed with `InferenceError::operationNotAllowed::Simulator is not supported` / `ModelManagerServices.ModelManagerError 1001`. An availability check alone is not proof that inference works. Updating the host is the next Simulator prerequisite, not a verified fix for that runtime error. An eligible physical iOS 27 device is an alternative.

## Implemented in this build

- Native onboarding and model/permission states, full or selected-photo access, ranked review list, editable Keep/Remove grid, next-group progression, deferred/kept history, full-screen inspection, zoom/comparison and Live playback controls.
- Incremental PhotoKit metadata enumeration, short temporal groups, bounded Vision comparisons, labelled image attachments and structured Foundation Models output. No model deletion tools. Missing Live motion prevents an actionable recommendation.
- Independent protections for favourites, edits, undeletable photos and retained keepers; complete model-ID and keeper-equivalence validation; revalidation at the PhotoKit deletion boundary.
- A reversible approval basket followed by one PhotoKit/system deletion request. Resource-size estimates include RAW and Live components, preserve unknown sizes, and never imply immediate device storage recovery.
- SwiftData checkpoints, explicit review history/preferences, cancellation and resume, preference invalidation, access-change reconciliation, opt-in weekly reminders after cleanup, and aggregate-only diagnostic sharing.
- Debug-only deterministic UI fixtures, isolated from the real Photos library and absent from Release builds. They exercise interface behaviour, not AI accuracy.

## Checks

Verified on 13 September 2026: 15 core tests, 4 iOS lifecycle/persistence tests and 2 UI tests passed. Debug Simulator and unsigned Release device builds succeeded. The separate real-model probe failed with the environment error above. Tests do not delete from the user's Photos library.

Pure Swift safety and bounded metadata tests (no Simulator required):

```sh
swift test
```

Deterministic iOS persistence/lifecycle and UI tests:

```sh
xcodebuild -project Curator.xcodeproj -scheme Curator \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test
```

Real on-device image integration gate, kept separate so a missing model is not mistaken for a safety-test failure:

```sh
xcodebuild -project Curator.xcodeproj -scheme CuratorModelProbe \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test
```

The probe sends a synthetic red image to the actual system model and checks its answer. A pass establishes image input transport only, **not** recommendation quality. A skipped or failed probe leaves milestone A incomplete. Use an eligible physical-device destination once signing is configured.

For deterministic UI inspection, add `--uitesting-fixtures` to the Debug scheme launch arguments. This loads an in-memory review group and geometric test images. Remove the argument to use the real app. It cannot activate in Release.

## Remaining gates

- Make the real image probe pass, then calibrate the provisional feature-distance threshold (0.45), four-photo chunks, 768px stills, two 512px Live motion samples, and prompt/output budgets on labelled photos. No accuracy claim yet.
- Exercise real RAW+JPEG and Live resources, limited/iCloud access, download cancellation on changing networks, deletion/system cancellation/recovery, on-disk termination/relaunch, and storage-pressure failures. Existing automated tests do not prove those PhotoKit behaviours.
- Implement and physically validate native continued-processing progress/background inference. **This build checkpoints and pauses when backgrounded.** It does not claim background scanning. Add entitlements only after verifying the required device/model support.
- Complete full-library performance/memory/thermal evaluation. The 100,000-record test covers metadata grouping only, not end-to-end scan performance. Current tests use an in-memory SwiftData store for lifecycle checks, not abrupt process termination.
- Validate large Dynamic Type, VoiceOver, reduced motion, contrast, dark mode, full-resolution comparison, Live playback failures and accessibility gestures. Add the final app icon, string-catalog plural/localization coverage, signing, support/privacy pages and App Store assets.
- Physical iPhone 15 Pro and newer-device testing, then the agreed broad TestFlight usefulness/safety gates before release.

Apple references: [image attachments](https://developer.apple.com/documentation/foundationmodels/analyzing-images-with-multimodal-prompting), [public resource sizes](https://developer.apple.com/documentation/photos/phassetresource/datasize-5lxva), [Simulator model requirements](https://developer.apple.com/forums/thread/787445).
