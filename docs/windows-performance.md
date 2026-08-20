# Windows: the performance rules, and why they exist

Snippr's Windows build is a tray utility with a violent shape. It idles for
hours, then one capture allocates several bitmaps **the size of the entire
virtual desktop** — 33 MB apiece on a 4K screen, more across two monitors —
paints them at mouse-move rate, and drops them a few seconds later.

Every rule below was written after something in that shape went wrong. They
cost nothing to keep and they are easy to undo by accident, so each one says
what it protects and which gate notices when it breaks.

If you are adding a feature and one of these is in your way, read the reason
first. They are not style preferences.

---

## 1. Never buffer a desktop-sized surface with WinForms' own double buffering

`DoubleBuffered = true` and `ControlStyles.OptimizedDoubleBuffer` ask
`BufferedGraphicsContext` for a bitmap the size of the control's **client
rectangle**. The shared context only caches buffers up to 225×96, so anything
bigger goes down the temporary-manager path: allocate, paint, free. On a
full-screen surface that is a 33 MB allocation and release **per paint** —
per mouse move during a drag.

Use `Ui/PaintBuffer.cs` instead. It grows to the largest paint asked of it,
stops allocating, and is disposed when the surface closes.

- `OverlayForm` (the selection marquee) and `OverlayToolbar` both do this.
- `AreaReviewForm` is deliberately **not** double-buffered: the toolbar is
  docked `Fill` over every one of its pixels and buffers itself, so the form's
  own paint is invisible and rare.

Small controls are fine with WinForms' buffering — the overlay buttons use it,
because 34×30 fits the shared cache.

## 2. Repaint the toolbar, never `Invalidate(true)` on the review form

`AreaReviewForm` is covered edge to edge by `OverlayToolbar`, which draws the
picture inside its own paint via the `PaintSurface` callback. So:

- `Invalidate(true)` on the form invalidates the form (whose paint nothing can
  see), the toolbar, **and recursively all twenty-one buttons**. One undo
  repainted the whole desktop twice and every button once.
- Use `InvalidateSurface(area)`. Pass a rectangle wherever you can.

`Dirty(mark, before, after)` computes that rectangle. If you add an annotation
type that draws **outside its own `Bounds`**, add it to the list that asks for
the whole crop instead — `SpotlightAnnotation` (dims everything around itself)
and `MagnifierAnnotation` (parks a callout anywhere in the picture) are there
for exactly that reason. Getting this wrong leaves stale pixels on screen.

Gate: smoke `review-partial-repaint-matches-full` photographs the real screen
mid-drag, forces a full repaint, and demands the same pixels.

## 3. The chrome names its own colours

A WinForms child does **not** inherit a `Color.Transparent` parent's
transparency unless it sets `SupportsTransparentBackColor` itself. WinForms
hands it `SystemColors.Control` instead — near-white, and it moves with the
Windows theme. That is how every overlay button shipped as a white slab in
1.2.14.

All overlay chrome painting lives in `Ui/OverlayChrome.cs`: static, over a
`Graphics`, every colour named, every pixel it is given written. Do not give a
chrome control a background and hope; do not read an ambient colour.

Gates: RasterGate `win-overlay-chrome-paints-its-own-colours` paints every
button state over a magenta sentinel; smoke `review-chrome-is-themed-not-system`
asks the same of the real surface and reports `plate=…px system=0px`.

## 4. No GDI+ objects built inside a paint

`Pen`, `SolidBrush`, `Region`, `Font` and `GraphicsPath` are unmanaged handles.
Building them per paint means building them per mouse move.

Hoist the ones that never vary to `static readonly` (they live for the
process — disposing them would only mean making them again). `AreaReviewForm`
and `OverlayForm` both keep their dim brush, crop pen, handle pen and bubble
font this way.

Special case, because it is easy to reach for: **do not use a `Region` to
describe a rectangle with a rectangular bite out of it.** That is the dim
around a crop, and it is at most four bands. `CropGeometry.Surround` returns
them into a `Span<Rectangle>`, so the per-frame path allocates nothing at all.

Gate: ParityGate `win-dim-bands-cover-exactly` walks the pixels and fails on a
missed one (a bright notch), a covered one (a veil over the picture) and one
painted twice (a dark patch — the dim is translucent).

## 5. Nothing that hashes, decodes or measures belongs in a paint

The backdrop grain tile is the example. `DrawGrain` used to call
`GrainBitmap(seed)` on every paint: a 64 KB `byte[]`, a `Bitmap`, a `LockBits`
and 16384 hashed pixels — per frame, on a desktop-sized surface, while the
user was drawing. The tiles never vary (the seed **is** the preset), so
`BackdropRender` caches them. There are at most four, 256 KB in total, kept
for the life of the process.

Gate: RasterGate `win-backdrop-grain-deterministic` now renders Ocean, Sunset,
Ocean and checks the two Oceans still match and still differ from Sunset —
a cache has one failure mode that painting afresh did not.

## 6. Diagnostics are not free

`Diag.Click` creates a directory, stats a file and appends to it, on the UI
thread, under a lock. `AreaReviewForm.PlaceToolbar` was calling it on every
frame of a crop drag; that stutter got blamed on the drawing for a while.

Log when something **changes**, not when something happens. `PlaceToolbar`
keeps the last line and stays quiet if it would repeat.

## 7. Give the memory back when the capture is over

The collector frees a dropped bitmap, but a freed large-object segment stays
mapped: resident memory keeps the high-water mark and the tray icon reads as
hundreds of megabytes it no longer uses.

`MemoryTrim.Schedule()` asks — once, debounced, and never while a surface is
up — for the collection that actually returns segments
(`LargeObjectHeapCompactionMode.CompactOnce` + an aggressive gen-2). Call it
wherever a capture-sized bitmap stops being reachable. It is wired into
`TrayContext.CaptureArea`'s `finally` and `EditorForm.DisposeBitmaps`.

It deliberately does **not** call `GC.WaitForPendingFinalizers`: that runs on
the UI thread, and a WinForms finalizer that marshals back to the thread it is
blocking is a deadlock. Nothing depends on finalizers here — every capture
bitmap is disposed explicitly, and it should stay that way.

## 8. Read and write locked bits directly for whole-image work

`AnnotationRenderer.Pixelate` used to stage the picture through two managed
`byte[]`s, so redacting a desktop capture cost three full-size buffers and two
copies of every pixel before a single block was averaged — about 100 MB in
flight to produce a 33 MB answer. It now walks `BitmapData.Scan0` both ways.

If you rewrite something in this class, pin it against the old one rather than
against your judgement: RasterGate `win-pixelate-matches-reference` keeps a
transcription of the previous implementation as an oracle and compares every
pixel, at sizes that are not multiples of the block. Keep that oracle a
transcription — if it is ever "tidied" to share code with the thing it checks,
it stops checking anything.

---

## What is deliberately NOT optimised

- **`Pixelate` covers the whole image, not just the blur rectangles.**
  `BlurAnnotation.Draw` clips to its own rect, so only those pixels are ever
  read, and pixelating just them would be far cheaper. It is not done because
  the result is cached and a new blur elsewhere would need the cache
  invalidated — and getting that wrong means a redaction that does not
  redact. It is not a hot path (once per session, once per export), so the
  memory was fixed and the semantics left alone.

- **`EditorForm.Prewarm()` at startup.** It builds and immediately disposes an
  editor to force the JIT and the WinForms/GDI+ load, so the first capture
  opens fast. It costs idle footprint. Left in on purpose; if you ever want it
  gone, measure the first-capture latency before and after.

- **`EditorForm.ScaledImage` at zoom 1.** Already short-circuited at the call
  site — the canvas blits `_image` directly rather than building a full-size
  "scaled" copy of it. Do not add a cache there.

---

## How to check any of this

There is no way to run the pixel gates on Linux or macOS: `System.Drawing`
throws `PlatformNotSupportedException` off Windows, and the WindowsDesktop
runtime is Windows-only. What you can run anywhere:

```bash
dotnet run --project windows/Snippr.Win.ParityGate/Snippr.Win.ParityGate.csproj -c Release -f net8.0
```

Everything else runs on `windows-latest` and starts itself on every push to a
working branch — see `.github/workflows/windows-ci.yml`. It builds all four
projects with warnings failing, runs the three gates, runs the headless
`--test-shot` smoke and prints its click log into the job, so a failure is
readable without downloading anything.

Push, then read the job. That is the loop.
