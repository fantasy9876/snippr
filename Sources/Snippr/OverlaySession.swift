import AppKit

// MARK: - Session model (plan: PLANS/SNIPPR_INPLACE_CAPTURE_OVERLAY.md, locked API)

/// Why the selection overlay was opened. Every caller states its purpose
/// explicitly — the old shared `.area` mode made Instant OCR, scroll-region
/// picking and interactive area review indistinguishable, so a review toolbar
/// added for one would leak into the others.
enum OverlayPurpose {
    /// Drag → capture → in-place review with toolbar (Lightshot flow).
    case areaReview
    /// Drag → hand the rect to ScrollingCapture. No review, no toolbar.
    case scrollRegion
    /// Drag → recognize immediately. No review, no toolbar.
    case instantOCRRegion
    /// Click a window to pick it.
    case windowPick
}

/// Behavior settings snapshotted ONCE when the session begins. Reducers and
/// the action router read these — never `Settings.shared` mid-session — so a
/// preference change while an overlay or scroll run is open cannot change the
/// session's behavior halfway through.
struct OverlaySessionInputs: Equatable {
    var afterShow: Bool
    var afterCopy: Bool
    var afterSave: Bool

    @MainActor
    static func snapshot() -> OverlaySessionInputs {
        let s = Settings.shared
        return OverlaySessionInputs(
            afterShow: s.afterShow, afterCopy: s.afterCopy,
            afterSave: s.afterSave)
    }
}

enum OverlaySessionPhase: Equatable {
    case selecting
    case reviewing
    case saving
    case completed
}

/// One state machine for the WHOLE session — never per view. Area overlays
/// exist on every display and secondary displays attach asynchronously, so
/// any per-view state would let a late screen fire `initialCapture` a second
/// time or resurrect a session a terminal action already closed.
@MainActor
final class OverlaySession {
    let purpose: OverlayPurpose
    let inputs: OverlaySessionInputs
    private(set) var phase: OverlaySessionPhase = .selecting
    /// Image-local, integral (pixel contract). Updated by the review UI on
    /// every accepted move/resize; actions always read this, never a live
    /// view rect.
    var pixelRect: CGRect = .null

    private var initialCaptureFired = false

    init(purpose: OverlayPurpose, inputs: OverlaySessionInputs) {
        self.purpose = purpose
        self.inputs = inputs
    }

    /// Whether the initial mouse-up leads into an in-place review. Derived
    /// from the session snapshot alone — callers cannot pass a contradicting
    /// flag.
    var presentsReview: Bool { purpose == .areaReview && inputs.afterShow }

    /// ATOMIC latch + phase move for the one-per-session mouse-up commit.
    /// The first caller wins and the phase leaves `.selecting` in the same
    /// step, so a competing intent can never slip through a latched-but-
    /// still-selecting gap. Late views and double-fires get false.
    func commitInitialCapture() -> Bool {
        // Only the area-review purpose owns this latch: scroll/OCR/window
        // sessions complete through the owner's finish() route instead.
        guard purpose == .areaReview,
              phase == .selecting, !initialCaptureFired else { return false }
        initialCaptureFired = true
        phase = presentsReview ? .reviewing : .completed
        return true
    }

    /// Legal transitions only, and review phases exist ONLY for the
    /// area-review purpose — a scroll/OCR/window-pick session can never
    /// wander into `.reviewing`/`.saving`. Anything illegal is ignored and
    /// reported false so racing callers can't corrupt the machine.
    @discardableResult
    func transition(to next: OverlaySessionPhase) -> Bool {
        if next == .reviewing || next == .saving {
            guard purpose == .areaReview else { return false }
        }
        switch (phase, next) {
        // NOTE: (.selecting → .reviewing) is deliberately absent — review is
        // reachable ONLY through the atomic commitInitialCapture latch, so a
        // stray transition call can never bypass the exactly-once guarantee.
        case (.selecting, .completed),
             (.reviewing, .saving),
             (.reviewing, .completed),
             (.saving, .reviewing),
             (.saving, .completed):
            phase = next
            return true
        default:
            return false
        }
    }

    /// Owner-only terminal route (SelectionOverlay.finish): the session must
    /// reach `.completed` from ANY phase exactly when the windows tear down,
    /// so there is a single source of truth for "this session is over".
    func forceComplete() {
        phase = .completed
    }

    /// Manual intents are accepted only during review — `.saving` swallows
    /// double-clicks, Enter and competing Saves; `.selecting` routes through
    /// `commitInitialCapture` instead.
    var acceptsCommits: Bool { phase == .reviewing }
}

/// Everything the scroll-finish routing needs, snapshotted at begin():
/// the stitched image, the behavior inputs, and the ORIGIN screen — a
/// Settings change or display-focus change mid-run must not reroute the
/// result (locked API, plan §Gợi ý API).
struct ScrollFinish {
    var image: CapturedImage?
    var inputs: OverlaySessionInputs
    /// nil only in screenless/headless environments — presentation is
    /// skipped there, but the payload must never crash constructing itself.
    var screen: NSScreen?
}

// MARK: - Action router

enum CaptureIntent: Equatable {
    /// The one-per-session mouse-up commit: runs the configured auto
    /// copy/save, sets `lastCapture`, writes the event log. NOT presentation —
    /// the session decides whether a review overlay appears.
    case initialCapture
    /// The one-per-session stitch-finished commit for the scroll panel:
    /// same auto-action matrix as `initialCapture`, but ONLY valid with the
    /// `.scrollResult` source and never records a Repeat-Area rect.
    case scrollFinished
    case copy
    case save
    case pin
    case ocr
    /// OCR the current flattened snapshot, copy the recognized source text,
    /// then immediately start translation in the result window.
    case translate
    case openEditor
}

enum CaptureCommitOutcome: Equatable {
    case completed
    /// Save is in flight; the overlay stays alive in `saving` phase until the
    /// resolution callback reports `.completed` / `.failed` / `.cancelled`.
    case saving
    case failed
    case cancelled
}

/// Typed Save-As result: user cancel and write failure are DIFFERENT states —
/// both return to review, but only failure warrants a toast, and neither
/// counts as a completed action (no `lastAreaRect` write).
enum SaveAsOutcome {
    case saved(URL)
    case cancelled
    case failed
}

/// Every user intention is exactly ONE `commit` call with the flattened
/// snapshot at the FINAL pixel rect. Auto-actions (`afterCopy`/`afterSave`)
/// run only for the two initial intents — `initialCapture` (area-review
/// mouse-up) and `scrollFinished` (stitch panel) — a manual Copy after
/// resize must not re-save, and vice versa (parity with
/// EditorWindow.swift:387-457, which never replays `handleResult`).
@MainActor
struct CaptureActionRouter {
    /// Side-effect seams. Tests inject spies; production uses `.live`.
    struct Dependencies {
        var copyToClipboard: @MainActor (CapturedImage) -> Void
        /// Auto-save to the screenshots folder (initialCapture's afterSave).
        var autoSave: @MainActor (CapturedImage, @escaping @MainActor (URL?) -> Void) -> Void
        /// Interactive Save-As panel (the toolbar's Save intent).
        var saveAs: @MainActor (CapturedImage, @escaping @MainActor (SaveAsOutcome) -> Void) -> Void
        var pin: @MainActor (CapturedImage) -> Void
        /// One recognition effect for both manual intents. `autoTranslate` is
        /// false for OCR and true only for the explicit Translate action.
        var ocr: @MainActor (CapturedImage, Bool) -> Void
        var openEditor: @MainActor (CapturedImage) -> Void
        var toast: @MainActor (String) -> Void
        var setLastCapture: @MainActor (CapturedImage) -> Void
        var setLastAreaRect: @MainActor (CGRect) -> Void
        var logEvent: @MainActor (String) -> Void

        /// Backward-compatible injection seam: existing tests and harnesses
        /// that do not care which OCR presentation was requested keep their
        /// one-argument closure. Translate still routes exactly once through
        /// that same injected effect.
        init(
            copyToClipboard: @escaping @MainActor (CapturedImage) -> Void,
            autoSave: @escaping @MainActor (
                CapturedImage, @escaping @MainActor (URL?) -> Void
            ) -> Void,
            saveAs: @escaping @MainActor (
                CapturedImage, @escaping @MainActor (SaveAsOutcome) -> Void
            ) -> Void,
            pin: @escaping @MainActor (CapturedImage) -> Void,
            ocr: @escaping @MainActor (CapturedImage) -> Void,
            openEditor: @escaping @MainActor (CapturedImage) -> Void,
            toast: @escaping @MainActor (String) -> Void,
            setLastCapture: @escaping @MainActor (CapturedImage) -> Void,
            setLastAreaRect: @escaping @MainActor (CGRect) -> Void,
            logEvent: @escaping @MainActor (String) -> Void
        ) {
            self.init(
                copyToClipboard: copyToClipboard,
                autoSave: autoSave,
                saveAs: saveAs,
                pin: pin,
                ocrWithMode: { image, _ in ocr(image) },
                openEditor: openEditor,
                toast: toast,
                setLastCapture: setLastCapture,
                setLastAreaRect: setLastAreaRect,
                logEvent: logEvent)
        }

        /// Mode-aware seam for S5 and future callers that must distinguish
        /// offline OCR presentation from explicit OCR + Translate.
        init(
            copyToClipboard: @escaping @MainActor (CapturedImage) -> Void,
            autoSave: @escaping @MainActor (
                CapturedImage, @escaping @MainActor (URL?) -> Void
            ) -> Void,
            saveAs: @escaping @MainActor (
                CapturedImage, @escaping @MainActor (SaveAsOutcome) -> Void
            ) -> Void,
            pin: @escaping @MainActor (CapturedImage) -> Void,
            ocrWithMode: @escaping @MainActor (CapturedImage, Bool) -> Void,
            openEditor: @escaping @MainActor (CapturedImage) -> Void,
            toast: @escaping @MainActor (String) -> Void,
            setLastCapture: @escaping @MainActor (CapturedImage) -> Void,
            setLastAreaRect: @escaping @MainActor (CGRect) -> Void,
            logEvent: @escaping @MainActor (String) -> Void
        ) {
            self.copyToClipboard = copyToClipboard
            self.autoSave = autoSave
            self.saveAs = saveAs
            self.pin = pin
            self.ocr = ocrWithMode
            self.openEditor = openEditor
            self.toast = toast
            self.setLastCapture = setLastCapture
            self.setLastAreaRect = setLastAreaRect
            self.logEvent = logEvent
        }

        static var live: Dependencies {
            Dependencies(
                copyToClipboard: { SaveService.shared.copyToClipboard($0) },
                autoSave: { image, done in SaveService.shared.save(image) { done($0) } },
                saveAs: { image, done in SaveService.shared.saveAs(image, completion: done) },
                pin: { PinWindow.pin($0) },
                ocrWithMode: { image, autoTranslate in
                    Task {
                        let result = await OCRService.shared.recognize(image.cgImage)
                        await MainActor.run {
                            let text = result.clipboardText
                            if text.isEmpty {
                                ToastHUD.show("No text found", symbol: "text.magnifyingglass")
                            } else {
                                SaveService.copyText(text)
                                TextResultWindow.show(
                                    text: text,
                                    autoTranslate: autoTranslate)
                            }
                        }
                    }
                },
                openEditor: { EditorWindowController.open(with: $0) },
                toast: { ToastHUD.show($0) },
                setLastCapture: { AppServices.lastCapture = $0 },
                setLastAreaRect: { Settings.shared.lastAreaRect = $0 },
                logEvent: { EventLog.append($0) }
            )
        }
    }

    /// True when this source + snapshot combination presents an in-place
    /// review/panel surface after the initial capture.
    static func presentsReview(
        source: CaptureSource, inputs: OverlaySessionInputs
    ) -> Bool {
        (source == .areaReview || source == .scrollResult) && inputs.afterShow
    }

    /// One intention = one call. The `finalGlobalRect` is HONORED only for
    /// the `.areaReview` source — the router enforces this itself instead of
    /// trusting callers, so scroll results, Instant OCR and legacy Repeat
    /// Area can never overwrite the remembered Repeat-Area rect
    /// (QA invariant 6).
    /// `resolution` is the async channel for `.saving` (invoked exactly once
    /// by the save intent); sync intents never call it.
    @discardableResult
    static func commit(
        _ snapshot: CapturedImage,
        source: CaptureSource,
        intent: CaptureIntent,
        inputs: OverlaySessionInputs,
        finalGlobalRect: CGRect?,
        dependencies: Dependencies? = nil,
        resolution: (@MainActor (CaptureCommitOutcome) -> Void)? = nil
    ) -> CaptureCommitOutcome {
        let deps = dependencies ?? .live
        let areaRect: CGRect? = source == .areaReview ? finalGlobalRect : nil

        func recordAreaRect() {
            if let areaRect { deps.setLastAreaRect(areaRect) }
        }

        func runInitialAutoActions(recordRectOnComplete: Bool) -> CaptureCommitOutcome {
            let reviewing = presentsReview(source: source, inputs: inputs)
            deps.setLastCapture(snapshot)
            deps.logEvent(
                "capture source=\(source) px=\(snapshot.cgImage.width)x\(snapshot.cgImage.height)")
            let copied = inputs.afterCopy
            if copied { deps.copyToClipboard(snapshot) }
            if inputs.afterSave {
                let announce = !reviewing
                deps.autoSave(snapshot) { url in
                    guard announce else { return }
                    var toasts: [String] = copied ? ["copied"] : []
                    if let url {
                        toasts.append("saved \(url.lastPathComponent)")
                    } else {
                        if !copied { deps.copyToClipboard(snapshot) }
                        toasts.append(copied ? "save failed" : "save failed — copied instead")
                    }
                    deps.toast("Screenshot \(toasts.joined(separator: " · "))")
                }
            } else if !reviewing {
                if copied {
                    deps.toast("Screenshot copied")
                } else {
                    // nothing configured, nothing shown — rescue the shot
                    deps.copyToClipboard(snapshot)
                    deps.toast("Screenshot copied to clipboard")
                }
            }
            if recordRectOnComplete, !reviewing { recordAreaRect() }
            return .completed
        }

        switch intent {
        case .initialCapture:
            // Only the interactive area-review mouse-up owns this intent —
            // wrong sources fail closed with ZERO side effects (QA: no
            // Repeat Area / fullscreen / scroll-end initialCapture).
            guard source == .areaReview else { return .failed }
            return runInitialAutoActions(recordRectOnComplete: true)

        case .scrollFinished:
            // Only the stitched scroll panel owns this intent; it never
            // records a Repeat-Area rect.
            guard source == .scrollResult else { return .failed }
            return runInitialAutoActions(recordRectOnComplete: false)

        case .copy:
            deps.setLastCapture(snapshot)
            deps.copyToClipboard(snapshot)
            deps.toast("Screenshot copied")
            recordAreaRect()
            return .completed

        case .save:
            // One-shot: a buggy or racing dependency that calls back twice
            // (or synchronously) must not double the cleanup, the toast or
            // the lastAreaRect write. The session enters `.saving` BEFORE
            // this call, so even a synchronous callback resolves against the
            // correct phase.
            var resolved = false
            deps.saveAs(snapshot) { outcome in
                guard !resolved else { return }
                resolved = true
                switch outcome {
                case let .saved(url):
                    deps.setLastCapture(snapshot)
                    deps.toast("Saved \(url.lastPathComponent)")
                    recordAreaRect()
                    resolution?(.completed)
                case .cancelled:
                    // back to review with state intact; not a completed
                    // action, so no lastAreaRect write
                    resolution?(.cancelled)
                case .failed:
                    deps.toast("Save failed")
                    resolution?(.failed)
                }
            }
            return .saving

        case .pin:
            deps.setLastCapture(snapshot)
            deps.pin(snapshot)
            recordAreaRect()
            return .completed

        case .ocr, .translate:
            deps.setLastCapture(snapshot)
            deps.ocr(snapshot, intent == .translate)
            recordAreaRect()
            return .completed

        case .openEditor:
            deps.setLastCapture(snapshot)
            deps.openEditor(snapshot)
            recordAreaRect()
            return .completed
        }
    }
}
