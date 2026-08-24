import AppKit
import SwiftUI

/// `Snippr --uitest <outdir>`: boots the real app, opens the Editor and
/// Preferences windows, snapshots every visible window to PNG, then exits.
/// Verifies the actual UI stack without needing Screen Recording permission.
@MainActor
enum UITest {
    static var requestedOutputDir: String? {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--uitest") else { return nil }
        return args.count > idx + 1 ? args[idx + 1] : NSTemporaryDirectory() + "snippr-uitest"
    }

    /// Types through the ACTIVE field editor. Setting `stringValue` while a
    /// field editor is live is silently clobbered: the commit path reads
    /// `stringValue`, whose getter runs `validateEditing()` — syncing the
    /// (still-empty) editor text back over the cell. insertText goes through
    /// the real typing machinery instead.
    private static func typeIntoField(_ field: NSTextField, _ text: String) {
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertText(
                text,
                replacementRange: NSRange(
                    location: 0, length: (editor.string as NSString).length))
        } else {
            field.stringValue = text
        }
    }

    static func runIfRequested() {
        guard let outDir = requestedOutputDir else { return }
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        // sample capture: gradient test card @2x
        let sample = CapturedImage(cgImage: SelfTest.makeTestImage(width: 1440, height: 900), scale: 2)
        let fittedEditor = EditorWindowController.open(with: sample, forceFitForTesting: true)
        // small shot in a deliberately oversized window — proves centering
        let small = CapturedImage(cgImage: SelfTest.makeTestImage(width: 600, height: 360), scale: 2)
        let smallEditor = EditorWindowController.open(with: small, forceFitForTesting: true)
        smallEditor.window?.setContentSize(NSSize(width: 820, height: 560))
        // Tall scrolling result: its fit factor is below the old 10% zoom
        // floor, which used to leave both scrollers visible in "Fit" mode.
        // Backdrop sidebar (Option A), open and wearing a gradient: the panel
        // is the one piece of editor chrome a snapshot has to catch, because
        // its width comes off the canvas and a layout mistake is invisible in
        // a headless gate.
        fittedEditor.canvasForTesting.applyBackdropStyle(
            BackdropStyle.gradient("lagoon"))
        fittedEditor.setBackdropPanelOpen(true)
        // Presets are INJECTED into the model rather than saved: the harness
        // must not write the user's defaults, and the row only needs a list to
        // render. Saving through the + button is covered by the gate.
        fittedEditor.backdropPanelModel?.presets = [
            BackdropNamedPreset(name: "Studio", style: .gradient("lagoon")),
            BackdropNamedPreset(name: "Docs light", style: .gradient("paper")),
        ]
        let tall = CapturedImage(cgImage: SelfTest.makeTestImage(width: 400, height: 24_000), scale: 2)
        let tallEditor = EditorWindowController.open(with: tall, forceFitForTesting: true)
        tallEditor.selectTool(.crop)
        // The panel is taller than a 520pt viewport, so the whole sidebar is
        // only visible in a tall window. Snapshot it there too rather than
        // trusting that what is below the scroll fold laid out.
        tallEditor.canvasForTesting.applyBackdropStyle(
            BackdropStyle.gradient("midnight"))
        tallEditor.setBackdropPanelOpen(true)
        tallEditor.backdropPanelModel?.presets = [
            BackdropNamedPreset(name: "Studio", style: .gradient("lagoon")),
        ]
        // opened the way the menu's "About Snippr" does — must land on About
        PreferencesWindowController.show(tab: .about)
        ToastHUD.show("Snippr UI test — toast OK", symbol: "checkmark.seal.fill", duration: 6)
        // Routed failure toast: must outrank a .screenSaver overlay on the
        // target screen (the area fail-closed path passes these values).
        ToastHUD.show(
            "UI test — toast above overlay", symbol: "exclamationmark.triangle.fill",
            duration: 6, on: NSScreen.main, above: .screenSaver)
        TextResultWindow.show(text: "Snippr — chụp màn hình, nhận diện chữ (OCR), dịch đa ngôn ngữ.\nScreenshot → OCR → Translate, everything on your machine.")
        ThumbnailHUD.show(sample) { _ in }
        PinWindow.pin(CapturedImage(cgImage: SelfTest.makeTestImage(width: 400, height: 260), scale: 2))

        // SwiftUI text layers don't always survive cacheDisplay — render each tab directly too
        let tabs: [(String, AnyView)] = [
            ("general", AnyView(GeneralTab())),
            ("hotkeys", AnyView(HotkeysTab())),
            ("uploading", AnyView(UploadingTab())),
            ("advanced", AnyView(AdvancedTab())),
            ("about", AnyView(AboutTab())),
        ]
        for (name, view) in tabs {
            let renderer = ImageRenderer(content: view.frame(width: 600).background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 2
            if let cg = renderer.cgImage {
                let rep = NSBitmapImageRep(cgImage: cg)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: "\(outDir)/prefs-\(name).png"))
                }
            }
        }

        // In-place area review factory case: real overlay window with an
        // injected frozen image (no Screen Recording), driven through the
        // production selection→review→escape-hatch path.
        var overlayReviewOK = false
        if let screen = NSScreen.main {
            let frozen = CapturedImage(
                cgImage: SelfTest.makeTestImage(width: 1200, height: 800), scale: 1)
            let editorsBefore = NSApp.windows.filter { $0.windowController is EditorWindowController }.count
            // no-op dependencies: the harness must never touch the user's
            // clipboard, files or settings
            var editorPresents = 0
            var lastEditorImage: CapturedImage?
            let noopDeps = CaptureActionRouter.Dependencies(
                copyToClipboard: { _ in },
                autoSave: { _, _ in },
                saveAs: { _, _ in },
                pin: { _ in }, ocr: { _ in },
                openEditor: { handoff in
                    editorPresents += 1
                    lastEditorImage = handoff.image
                    EditorWindowController.open(
                        with: handoff.image,
                        annotations: handoff.annotations)
                },
                toast: { _ in },
                setLastCapture: { _ in },
                setLastAreaRect: { _ in },
                logEvent: { _ in })
            let overlay = SelectionOverlay.beginForTesting(
                purpose: .areaReview,
                inputs: OverlaySessionInputs(
                    afterShow: true, afterCopy: false, afterSave: false),
                frozen: frozen, screen: screen,
                dependencies: noopDeps, completion: { _ in })
            if let overlay,
               let view = overlay.activeReviewViewForTesting {
                view.selectForTesting(rect: CGRect(x: 120, y: 140, width: 360, height: 240))
                let toolbarFrame = view.reviewToolbarFrameForTesting
                let reviewing = view.isReviewingForTesting
                    && overlay.session.phase == .reviewing
                let toolbarInside = toolbarFrame.map { view.bounds.contains($0) } ?? false
                // annotation + text-responder precedence: while the text
                // field is first responder, Return must stay in the field —
                // the overlay survives.
                // blue rect: its right edge (crop x=200) falls inside the
                // typed-text probe window — red would green the ink probe
                // without any text
                view.annotationSurface?.color = .systemBlue
                view.annotationSurface?.tool = .rect
                _ = view.annotationSurface?.beginDrag(
                    atPixel: CGPoint(x: 200, y: 220))
                view.annotationSurface?.continueDrag(
                    toPixel: CGPoint(x: 320, y: 300))
                view.annotationSurface?.endDrag()
                view.annotationSurface?.color = .systemRed
                let annotated = view.annotationSurface?.isEmpty == false
                view.annotationSurface?.tool = .text
                view.beginTextEntryForTesting(
                    atView: CGPoint(x: 200, y: 200))
                var precedenceOK = false
                if let field = view.textFieldForTesting,
                   view.window?.firstResponder === field
                    || view.window?.firstResponder is NSTextView {
                    if let returnEvent = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                        context: nil, characters: "\r",
                        charactersIgnoringModifiers: "\r",
                        isARepeat: false, keyCode: 36) {
                        view.keyDown(with: returnEvent)
                    }
                    precedenceOK = SelectionOverlay.current != nil
                }
                // While typing, a real click OUTSIDE the selection must NOT
                // cancel the session; after the entry commits, the same
                // click cancels exactly once.
                var textOutsideClickOK = false
                if view.isReviewingForTesting,
                   let outside = NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: CGPoint(x: 30, y: 30), // outside 120,140,360,240
                    modifierFlags: [], timestamp: 0,
                    windowNumber: view.window?.windowNumber ?? 0,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    view.mouseDown(with: outside)
                    textOutsideClickOK = SelectionOverlay.current != nil
                        && overlay.session.phase == .reviewing
                        && view.textFieldForTesting != nil
                }
                view.commitTextEntryForTesting(text: "hello")
                // Terminal-vs-typing race: an ACTIVE entry (typed, NO
                // Return) must be committed by the terminal itself and
                // appear in the exported image — here through the escape
                // hatch, which shares performReviewAction with every
                // terminal button.
                view.annotationSurface?.tool = .text
                view.beginTextEntryForTesting(atView: CGPoint(x: 300, y: 250))
                if let typedField = view.textFieldForTesting {
                    typeIntoField(typedField, "typed")
                }
                let annBeforeTerminal =
                    view.annotationSurface?.annotations.count ?? -1
                // escape hatch: exactly one editor presented AFTER teardown
                view.performReviewActionForTesting(.openEditor)
                let terminalCommittedText =
                    view.annotationSurface?.annotations.count
                        == annBeforeTerminal + 1
                    && view.textFieldForTesting == nil
                // "typed" origin: view (300, 238) → crop-relative (180, 98)
                // in the 360×240 export (selection 120,140,360,240, scale 1)
                let typedInkOK = lastEditorImage.map {
                    $0.cgImage.width == 360 && $0.cgImage.height == 240
                        && SelfTest.redInkNearForTesting(
                            $0.cgImage,
                            points: [CGPoint(x: 185, y: 105)],
                            pixelRadius: 30) != nil
                } ?? false
                let editorsAfter = NSApp.windows.filter { $0.windowController is EditorWindowController }.count
                overlayReviewOK = reviewing && toolbarInside
                    && SelectionOverlay.current == nil
                    && editorsAfter == editorsBefore + 1
                    && editorPresents == 1
                    && annotated && precedenceOK && textOutsideClickOK
                    && terminalCommittedText && typedInkOK
            }
        }

        // Scroll-result panel factory case: 24k-pt stitch fits ≤90% of the
        // visible frame, toolbar visible, escape hatch presents exactly one
        // editor AFTER the panel dismissed.
        var scrollPanelOK = false
        var panelPreviewOK = false
        if let screen = NSScreen.main {
            let tallStitch = CapturedImage(
                cgImage: SelfTest.makeTestImage(width: 400, height: 24_000), scale: 2)
            let editorsBefore = NSApp.windows
                .filter { $0.windowController is EditorWindowController }.count
            var panelEditorPresents = 0
            var panelDepsToastCounter: () -> Void = {}
            var panelDepsCopyCounter: () -> Void = {}
            var panelDepsSaveHold = false
            var panelHeldSaveResolution: (@MainActor (SaveAsOutcome) -> Void)?
            let panelDeps = CaptureActionRouter.Dependencies(
                copyToClipboard: { _ in panelDepsCopyCounter() },
                autoSave: { _, _ in },
                saveAs: { _, done in
                    if panelDepsSaveHold {
                        panelHeldSaveResolution = done
                    } else {
                        done(.cancelled)
                    }
                },
                pin: { _ in }, ocr: { _ in },
                openEditor: { handoff in
                    panelEditorPresents += 1
                    EditorWindowController.open(
                        with: handoff.image,
                        annotations: handoff.annotations)
                },
                toast: { _ in panelDepsToastCounter() },
                setLastCapture: { _ in },
                setLastAreaRect: { _ in },
                logEvent: { _ in })
            let panel = ScrollResultPanel.show(
                image: tallStitch,
                inputs: OverlaySessionInputs(
                    afterShow: true, afterCopy: false, afterSave: false),
                screen: screen,
                dependencies: panelDeps)
            let visible = screen.visibleFrame
            let fits = panel.frame.width <= visible.width * 0.9 + 1
                && panel.frame.height <= visible.height * 0.9 + 1
            // must be able to join another app's native-fullscreen Space:
            // the router already suppressed the rescue copy for this panel
            let spacesOK = panel.collectionBehavior.contains(.canJoinAllSpaces)
                && panel.collectionBehavior.contains(.fullScreenAuxiliary)
            // toolbar layout is REAL: every button (Close included) inside
            // the bar, no pairwise overlap, and each hit-tests to itself
            var toolbarVisible = panel.toolbarFrameForTesting != nil
            if let bar = panel.toolbarFrameForTesting {
                let frames = panel.toolbarButtonFramesForTesting
                let barBounds = CGRect(origin: .zero, size: bar.size)
                for (i, f) in frames.enumerated() {
                    if !barBounds.contains(f) { toolbarVisible = false }
                    for j in (i + 1)..<frames.count
                        where f.intersects(frames[j]) {
                        toolbarVisible = false
                    }
                }
                if let content = panel.contentView {
                    for f in frames {
                        let centerInContent = CGPoint(
                            x: bar.minX + f.midX, y: bar.minY + f.midY)
                        if !(content.hitTest(centerInContent) is NSButton) {
                            toolbarVisible = false
                        }
                    }
                }
            }
            // WYSIWYG preview: on the fixed-fit panel a Pen stroke must be
            // VISIBLY thick — the authoring scale is pixelsPerPoint, not
            // image.scale. Cross-section through the midpoint of an
            // off-center stroke in the RENDERED host: exactly one contiguous
            // run, ~3 view pt thick, centroid on the stroke line (off-center
            // endpoints turn an axis flip into a centroid miss). With
            // image.scale authoring the run measures ≤1 px → gate red.
            if let host = panel.annotationHostForTesting {
                panel.annotationSurface.tool = .pen
                panel.annotationSurface.color = .systemRed
                let annBeforePreview = panel.annotationSurface.annotations.count
                let w = host.bounds.width, h = host.bounds.height
                let a = CGPoint(x: w * 0.15, y: h * 0.4)
                let b = CGPoint(x: w * 0.8, y: h * 0.4)
                panel.drawWithRealEventsForTesting(fromView: a, toView: b)
                if panel.annotationSurface.annotations.count == annBeforePreview + 1,
                   let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let repScale = CGFloat(rep.pixelsHigh) / max(1, h)
                    let col = min(
                        rep.pixelsWide - 1,
                        Int((a.x + b.x) / 2 / max(1, w) * CGFloat(rep.pixelsWide)))
                    var runs: [(count: Int, sumRow: CGFloat)] = []
                    var run: (count: Int, sumRow: CGFloat)?
                    for row in 0..<rep.pixelsHigh {
                        let c = rep.colorAt(x: col, y: row)?
                            .usingColorSpace(.deviceRGB)
                        let red = c.map {
                            $0.alphaComponent > 0.4 && $0.redComponent > 0.6
                                && $0.redComponent > $0.greenComponent + 0.25
                                && $0.redComponent > $0.blueComponent + 0.25
                        } ?? false
                        if red {
                            run = ((run?.count ?? 0) + 1,
                                   (run?.sumRow ?? 0) + CGFloat(row))
                        } else if let finished = run {
                            runs.append(finished)
                            run = nil
                        }
                    }
                    if let finished = run { runs.append(finished) }
                    if runs.count == 1, let stroke = runs.first {
                        let thicknessPt = CGFloat(stroke.count) / repScale
                        // rep rows count from the TOP; view y is bottom-up
                        let centroidViewY =
                            h - (stroke.sumRow / CGFloat(stroke.count)) / repScale
                        panelPreviewOK = thicknessPt >= 2 && thicknessPt <= 4.5
                            && abs(centroidViewY - a.y) <= 2.5
                    }
                }
                _ = panel.annotationSurface.undo() // clean slate for the probes
            }

            // Annotate through REAL mouse events at the four corners and
            // the center of the fitted strip: each stroke must land at the
            // matching pixel in the export (uniform X/Y mapping), and the
            // export keeps the stitched dimensions.
            panel.annotationSurface.tool = .pen
            panel.annotationSurface.color = .systemRed
            var panelAnnotated = true
            var exportForProbes: CapturedImage?
            if let host = panel.annotationHostForTesting {
                // uniform mapping: pixels-per-point equal on both axes
                let ppx = CGFloat(tallStitch.cgImage.width) / host.frame.width
                let ppy = CGFloat(tallStitch.cgImage.height) / host.frame.height
                if abs(ppx - ppy) > 0.02 * max(ppx, ppy) { panelAnnotated = false }
                let w = host.bounds.width, h = host.bounds.height
                let probes: [CGPoint] = [
                    CGPoint(x: 2, y: 2), CGPoint(x: w - 2, y: 2),
                    CGPoint(x: 2, y: h - 2), CGPoint(x: w - 2, y: h - 2),
                    CGPoint(x: w / 2, y: h / 2),
                ]
                for p in probes {
                    panel.drawWithRealEventsForTesting(
                        fromView: p,
                        toView: CGPoint(x: min(w - 1, p.x + 1), y: p.y))
                }
                if let export = panel.exportSnapshotForTesting {
                    if export.cgImage.width != tallStitch.cgImage.width
                        || export.cgImage.height != tallStitch.cgImage.height
                        || SelfTest.imagesEqualForTesting(
                            export.cgImage, tallStitch.cgImage) {
                        panelAnnotated = false
                    }
                    exportForProbes = export
                } else {
                    panelAnnotated = false
                }
                // every probe pixel neighborhood must contain red ink
                if let exportImage = exportForProbes,
                   let probe = SelfTest.redInkNearForTesting(
                    exportImage.cgImage,
                    points: probes.map { CGPoint(x: $0.x * ppx, y: $0.y * ppy) },
                    pixelRadius: Int(8 * max(ppx, 1))) {
                    _ = probe
                } else {
                    panelAnnotated = false
                }
            } else {
                panelAnnotated = false
            }
            // Panel force-fail export: 0 actions, panel STAYS, one toast.
            var panelFailOK = false
            panel.annotationSurface.forceRenderFailureForTesting = true
            var failToasts = 0
            var failCopies = 0
            panelDepsToastCounter = { failToasts += 1 }
            panelDepsCopyCounter = { failCopies += 1 }
            let annBeforeFail = panel.annotationSurface.annotations.count
            panel.performActionForTesting(.copy)
            panelFailOK = failCopies == 0 && failToasts == 1
                && ScrollResultPanel.current === panel
                && panel.annotationSurface.annotations.count == annBeforeFail
            panel.annotationSurface.forceRenderFailureForTesting = false

            // Panel save-lock with REAL events: drags + Cmd-Z during an
            // in-flight save leave the annotation count unchanged; drawing
            // resumes after cancel.
            var panelSaveLockOK = false
            let annBefore = panel.annotationSurface.annotations.count
            panelDepsSaveHold = true
            panel.performActionForTesting(.save)
            // step-wise: assert after the drag AND after Cmd-Z separately —
            // +1/−1 cancellation must not hide two missing guards
            panel.drawWithRealEventsForTesting(
                fromView: CGPoint(x: 10, y: 10),
                toView: CGPoint(x: 30, y: 30))
            let panelInvariantAfterDrag =
                panel.annotationSurface.annotations.count == annBefore
            func panelCmdZ() {
                if let cmdZ = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.command],
                    timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                    characters: "z", charactersIgnoringModifiers: "z",
                    isARepeat: false, keyCode: 6) {
                    _ = panel.performKeyEquivalent(with: cmdZ)
                }
            }
            panelCmdZ()
            let panelInvariantAfterUndo =
                panel.annotationSurface.annotations.count == annBefore
            panelHeldSaveResolution?(.cancelled)
            panel.drawWithRealEventsForTesting(
                fromView: CGPoint(x: 12, y: 40),
                toView: CGPoint(x: 40, y: 60))
            let panelDrawsAfterCancel =
                panel.annotationSurface.annotations.count == annBefore + 1
            panelCmdZ()
            let panelUndoAfterCancel =
                panel.annotationSurface.annotations.count == annBefore
            panelSaveLockOK = panelInvariantAfterDrag
                && panelInvariantAfterUndo
                && panelDrawsAfterCancel && panelUndoAfterCancel

            panel.performActionForTesting(.openEditor)
            let editorsAfter = NSApp.windows
                .filter { $0.windowController is EditorWindowController }.count
            scrollPanelOK = fits && spacesOK && toolbarVisible
                && ScrollResultPanel.current == nil
                && editorsAfter == editorsBefore + 1
                && panelEditorPresents == 1
                && panelAnnotated && panelFailOK && panelSaveLockOK
        }

        // Terminal-vs-typing race on the panel: for EVERY terminal button,
        // an ACTIVE text entry (typed, NO Return) must be committed by the
        // terminal itself and carry red ink into the routed image. All
        // interaction is real: Text tool button click, production mouse
        // click placing the field, terminal button click. A tool switch
        // away from Text commits too (area parity).
        var panelTextTerminalsOK = false
        if let screen = NSScreen.main {
            var terminalsOK = true
            let stitch = CapturedImage(
                cgImage: SelfTest.makeTestImage(width: 400, height: 8000),
                scale: 2)
            let inputs = OverlaySessionInputs(
                afterShow: true, afterCopy: false, afterSave: false)
            // Drive every terminal descriptor from the shared area/panel
            // catalog, including explicit OCR + Translate.
            for tag in OverlayActionCatalog.items.indices {
                var routed: CapturedImage?
                let deps = CaptureActionRouter.Dependencies(
                    copyToClipboard: { routed = $0 },
                    autoSave: { _, _ in },
                    saveAs: { image, done in
                        routed = image
                        done(.cancelled)
                    },
                    pin: { routed = $0 }, ocr: { routed = $0 },
                    openEditor: { routed = $0.image },
                    toast: { _ in },
                    setLastCapture: { _ in },
                    setLastAreaRect: { _ in }, logEvent: { _ in })
                let p = ScrollResultPanel.show(
                    image: stitch, inputs: inputs, screen: screen,
                    dependencies: deps)
                guard let host = p.annotationHostForTesting else {
                    terminalsOK = false
                    break
                }
                p.annotationSurface.color = .systemRed
                p.clickToolbarButtonForTesting(tag: 100 + 4) // Text tool
                let fieldPoint = CGPoint(
                    x: host.bounds.width / 2, y: host.bounds.height / 2)
                p.drawWithRealEventsForTesting(
                    fromView: fieldPoint, toView: fieldPoint)
                guard let field = host.textFieldForTesting else {
                    terminalsOK = false
                    break
                }
                typeIntoField(field, "Gk") // typed for real, no Return
                let annBefore = p.annotationSurface.annotations.count
                p.clickToolbarButtonForTesting(tag: tag)
                let committed =
                    p.annotationSurface.annotations.count == annBefore + 1
                    && host.textFieldForTesting == nil
                let ppx = CGFloat(stitch.cgImage.width) / host.bounds.width
                let inkOK = routed.map {
                    SelfTest.redInkNearForTesting(
                        $0.cgImage,
                        points: [CGPoint(
                            x: fieldPoint.x * ppx,
                            y: (fieldPoint.y - 12 + 9) * ppx)],
                        pixelRadius: Int(20 * ppx)) != nil
                } ?? false
                if !(committed && inkOK) { terminalsOK = false }
                if ScrollResultPanel.current === p { // save stays open
                    p.clickToolbarButtonForTesting(tag: -1)
                }
            }
            // tool switch away from Text commits the entry (real clicks)
            let p2 = ScrollResultPanel.show(
                image: stitch, inputs: inputs, screen: screen,
                dependencies: CaptureActionRouter.Dependencies(
                    copyToClipboard: { _ in }, autoSave: { _, _ in },
                    saveAs: { _, _ in }, pin: { _ in }, ocr: { _ in },
                    openEditor: { _ in }, toast: { _ in },
                    setLastCapture: { _ in }, setLastAreaRect: { _ in },
                    logEvent: { _ in }))
            var toolSwitchCommitOK = false
            if let host2 = p2.annotationHostForTesting {
                p2.clickToolbarButtonForTesting(tag: 100 + 4) // Text tool
                let mid = CGPoint(
                    x: host2.bounds.width / 2, y: host2.bounds.height / 2)
                p2.drawWithRealEventsForTesting(fromView: mid, toView: mid)
                if let switchField = host2.textFieldForTesting {
                    typeIntoField(switchField, "Sw")
                }
                let before2 = p2.annotationSurface.annotations.count
                p2.clickToolbarButtonForTesting(tag: 100 + 1) // Pen tool
                toolSwitchCommitOK =
                    p2.annotationSurface.annotations.count == before2 + 1
                    && host2.textFieldForTesting == nil
            }
            p2.clickToolbarButtonForTesting(tag: -1)
            panelTextTerminalsOK = terminalsOK && toolSwitchCommitOK
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // the routed toast was shown LAST, so the live toast panel must
            // carry its level (> .screenSaver) and sit on the target screen
            let toastStyleOn = Settings.shared.confirmationStyle != .none
            var toastAboveOverlayOK = true
            if toastStyleOn {
                let toastPanel = ToastHUD.panelForTesting
                toastAboveOverlayOK =
                    (toastPanel?.level.rawValue ?? 0)
                        > NSWindow.Level.screenSaver.rawValue
                    && (toastPanel.flatMap { p in
                        NSScreen.main.map { p.frame.intersects($0.frame) }
                    } ?? false)
            } else {
                print("UITEST toast-above-overlay SKIP "
                      + "(confirmationStyle=none) — MUST re-run with toasts on")
            }
            let fitOK = fittedEditor.imageFitsViewportForTesting()
                && smallEditor.imageFitsViewportForTesting()
                && tallEditor.imageFitsViewportForTesting()
            let tallCropControlsOK = tallEditor.cropActionControlsReadyForTesting()
            // ⌘+scroll zoom on the tall (scroll-capture-like) editor: a
            // positive wheel delta zooms IN (or out with the reverse pref)
            // and a subsequent opposite delta moves back.
            var cmdZoomOK = false
            if let zoomIn = tallEditor.commandScrollZoomForTesting(deltaY: 40),
               let zoomOut = tallEditor.commandScrollZoomForTesting(deltaY: -40) {
                let reverse = Settings.shared.zoomReverseScroll
                let inOK = reverse ? zoomIn.after < zoomIn.before : zoomIn.after > zoomIn.before
                let outOK = reverse ? zoomOut.after > zoomOut.before : zoomOut.after < zoomOut.before
                cmdZoomOK = inOK && outOK
                print("UITEST editor-cmd-scroll-zoom detail in \(zoomIn.before)→\(zoomIn.after) out \(zoomOut.before)→\(zoomOut.after)")
            }
            print("UITEST editor-fit \(fitOK ? "PASS" : "FAIL")")
            print("UITEST tall-crop-controls \(tallCropControlsOK ? "PASS" : "FAIL")")
            print("UITEST editor-cmd-scroll-zoom \(cmdZoomOK ? "PASS" : "FAIL")")
            print("UITEST overlay-review \(overlayReviewOK ? "PASS" : "FAIL")")
            print("UITEST scroll-panel \(scrollPanelOK ? "PASS" : "FAIL")")
            print("UITEST scroll-panel-preview \(panelPreviewOK ? "PASS" : "FAIL")")
            print("UITEST panel-text-terminals \(panelTextTerminalsOK ? "PASS" : "FAIL")")
            if toastStyleOn {
                print("UITEST toast-above-overlay \(toastAboveOverlayOK ? "PASS" : "FAIL")")
            }
            var index = 0
            for window in NSApp.windows where window.isVisible {
                guard let view = window.contentView, view.bounds.width > 10 else { continue }
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                guard let data = rep.representation(using: .png, properties: [:]) else { continue }
                let kind = window is NSPanel ? "panel" : "window"
                let name = String(format: "%02d-%@-%.0fx%.0f.png", index, kind, view.bounds.width, view.bounds.height)
                try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
                index += 1
            }
            print("UITEST captured \(index) windows → \(outDir)")
            exit(index >= 3 && fitOK && tallCropControlsOK && cmdZoomOK && overlayReviewOK
                 && scrollPanelOK && panelPreviewOK
                 && panelTextTerminalsOK && toastAboveOverlayOK ? 0 : 1)
        }
    }
}
