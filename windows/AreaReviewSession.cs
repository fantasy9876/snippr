using System.Drawing;
using System.Drawing.Imaging;

namespace Snippr;

/// The state behind reviewing a capture in place, before it goes anywhere.
///
/// The form around it draws and routes clicks; everything that decides what
/// the user ends up with lives here, so it can be checked without a screen.
///
/// The crop is ONE authority. `PixelRect` is the integral rect the export
/// crops by, and `Selection` is that rect mapped back — so the border, the dim
/// hole, the toolbar, the frame and the rect handed to the router all describe
/// the picture that is actually produced. On macOS the fractional selection
/// stayed live beside the integral one and everything on screen sat half a
/// point away from the export at scale 2.
sealed class AreaReviewSession
{
    /// The whole frozen desktop. Annotations are positioned in ITS pixels,
    /// absolutely: moving the crop must not drag the drawings along.
    public Bitmap Frozen { get; }
    public List<Annotation> Annotations { get; } = new();
    public BackdropPreset Backdrop { get; private set; } = BackdropPreset.None;

    /// How round the plate's corners are. Handed IN by the surface that owns
    /// the user's settings rather than read from them here: this type is
    /// compiled into a gate that has no settings file and no reason to want
    /// one.
    public BackdropCornerStyle Corners { get; set; } = BackdropSpec.DefaultCornerStyle;

    readonly Timeline<AreaReviewState> _history = new();
    Rectangle _selection;

    public AreaReviewSession(Bitmap frozen, Rectangle selection)
    {
        Frozen = frozen;
        _selection = Canonical(selection);
    }

    /// The crop, in frozen-image pixels. Always integral, always inside the
    /// image, never smaller than a pixel.
    public Rectangle PixelRect => _selection;

    /// Same rect, offered under the name the UI thinks in.
    public Rectangle Selection => _selection;

    Rectangle Canonical(Rectangle proposed) =>
        CropGeometry.Canonical(proposed, new Size(Frozen.Width, Frozen.Height));

    /// Moving or resizing the crop is not an edit of the document: the marks
    /// stay where they were put, and what changes is how much of them survives.
    public void SetSelection(Rectangle proposed) => _selection = Canonical(proposed);

    // ---------- history ----------

    AreaReviewState Snapshot() => new(
        Annotations.Select(a => a.Clone()).ToList(), Backdrop);

    public bool CanUndo => _history.CanUndo;
    public bool CanRedo => _history.CanRedo;

    public void PushUndo() => _history.Push(Snapshot());

    public bool Undo()
    {
        if (!_history.TryUndo(Snapshot(), out var previous)) return false;
        Restore(previous);
        return true;
    }

    public bool Redo()
    {
        if (!_history.TryRedo(Snapshot(), out var next)) return false;
        Restore(next);
        return true;
    }

    void Restore(AreaReviewState state)
    {
        Annotations.Clear();
        Annotations.AddRange(state.Annotations);
        Backdrop = state.Backdrop;
    }

    public void Add(Annotation annotation)
    {
        PushUndo();
        // One spotlight until WP8. macOS 1.2.14 keeps several holes behind
        // Settings.multipleSpotlight and unions them in the compositor.
        if (annotation is SpotlightAnnotation)
            Annotations.RemoveAll(a => a is SpotlightAnnotation);
        Annotations.Add(annotation);
    }

    /// A preset is one step on the SAME timeline as the marks, and choosing
    /// the one already in use is no step at all.
    public bool ApplyBackdrop(BackdropPreset preset)
    {
        if (preset == Backdrop) return false;
        PushUndo();
        Backdrop = preset;
        return true;
    }

    // ---------- payloads ----------

    bool NeedsPixelated =>
        Annotations.Any(a => a is BlurAnnotation)
            || Annotations.OfType<MagnifierAnnotation>().Any();

    /// The DOCUMENT: the crop with its marks, undecorated. What the recognizer
    /// reads, and what `LastArea` describes.
    public Bitmap Semantic()
    {
        var crop = PixelRect;
        var result = new Bitmap(crop.Width, crop.Height, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(result);
        g.DrawImage(
            Frozen, new Rectangle(0, 0, crop.Width, crop.Height), crop, GraphicsUnit.Pixel);
        // The marks are drawn in the FROZEN image's coordinates and shifted
        // into the crop's, so anything outside the crop is clipped rather than
        // dragged along — and the compositor is told what the crop is, which
        // is what stops a magnifier whose source has fallen outside it.
        using var pixelated = NeedsPixelated ? AnnotationRenderer.Pixelate(Frozen) : null;
        var state = g.Save();
        g.TranslateTransform(-crop.X, -crop.Y);
        AnnotationCompositor.Draw(Annotations, g, Frozen, crop, pixelated);
        g.Restore(state);
        return result;
    }

    /// The PICTURE: the document inside its frame.
    public Bitmap Visual()
    {
        var inner = Semantic();
        if (Backdrop == BackdropPreset.None) return inner;
        var composed = BackdropRender.Compose(inner, Backdrop, corners: Corners);
        if (composed == null || ReferenceEquals(composed, inner)) return inner;
        inner.Dispose();
        return composed;
    }

    /// One freeze, two readings; which one a route gets is looked up, not
    /// decided again here.
    public Bitmap ForRoute(OverlayAction action) =>
        RouteDecoration.UsesDecoration(action) ? Visual() : Semantic();

    /// What the size badge promises, which is what the export writes.
    public Size ExportedSize =>
        BackdropSpec.OuterDimensions(PixelRect.Width, PixelRect.Height, Backdrop)
            ?? PixelRect.Size;

    /// Samples a callout's source once, after the redactions — the same rule
    /// the editor uses, kept here so the review surface cannot acquire a
    /// weaker one.
    public MagnifierAnnotation? MakeMagnifier(
        Rectangle source, float zoom = MagnifierAnnotation.DefaultZoom)
    {
        var region = Rectangle.Intersect(source, PixelRect);
        if (region.Width <= 4 || region.Height <= 4) return null;
        var snapshot = AnnotationCompositor.MagnifierSnapshot(
            Frozen, region, Annotations.OfType<BlurAnnotation>());
        if (snapshot == null) return null;
        // Parked inside the CROP, not merely inside the desktop: a callout
        // outside the crop is one the export drops and the user cannot reach.
        return new MagnifierAnnotation
        {
            SourceRect = region,
            CalloutRect = MagnifierAnnotation.PlaceCallout(region, PixelRect, zoom),
            Snapshot = snapshot,
        };
    }
}

/// One point on the review surface's timeline: the marks and the frame. The
/// frozen desktop is not on it — the crop can move, but the capture itself
/// never changes while it is being reviewed.
readonly record struct AreaReviewState(
    List<Annotation> Annotations, BackdropPreset Backdrop);
