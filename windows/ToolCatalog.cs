namespace Snippr;

/// The drawing tools, in toolbar order.
///
/// Appended at the END: stroke widths are persisted under `nameof(Tool.X)`,
/// and every toolbar is ordered by this enum, so inserting in the middle would
/// silently renumber both. It lives beside the catalog rather than beside the
/// annotations because the headless gate reads it and cannot load GDI+.
enum Tool
{
    Select, Arrow, Line, Rect, Oval, Highlight, Pen, Text, Counter, Blur, Crop,
    Spotlight, Magnifier,
}

/// Everything a button can do that is not a drawing tool. Backdrop is here
/// rather than in `Tool` on purpose: picking a preset is a document STYLE, so
/// it must not displace the active tool or start a drag — the same shape the
/// macOS build settled on.
enum OverlayAction
{
    Backdrop,
    Color,
    Undo,
    Redo,
    Copy,
    Save,
    Pin,
    Ocr,
    Translate,
    OpenEditor,
    Close,
}

/// One drawing tool, as every surface sees it.
///
/// `KeyLabel` is the text the user reads ("V", "Ctrl+Z"), NOT a WinForms key:
/// this table is compiled into the headless parity gate, which targets plain
/// `net8.0`/`net10.0` and therefore cannot reference `System.Windows.Forms`.
/// The mapping to `Keys` lives beside the app in `ToolCatalogKeys.cs`.
readonly record struct ToolEntry(
    Tool Tool,
    string Name,
    string KeyLabel,
    string IconKey,
    bool InEditor,
    bool InOverlay)
{
    public string HintText =>
        KeyLabel.Length == 0 ? Name : $"{Name} ({KeyLabel})";
}

readonly record struct ActionEntry(
    OverlayAction Action,
    string Name,
    string KeyLabel,
    string IconKey,
    bool InEditor,
    bool InOverlay)
{
    public string HintText =>
        KeyLabel.Length == 0 ? Name : $"{Name} ({KeyLabel})";
}

/// The ONE table. Toolbars, the hover hint, the keyboard router and the gates
/// all read it, so a tool cannot appear in one host with a name or a key that
/// another host disagrees about — which is exactly how the macOS toolbar ended
/// up advertising shortcuts that no host routed.
static class ToolCatalog
{
    public static readonly IReadOnlyList<ToolEntry> Entries = new[]
    {
        new ToolEntry(Tool.Select, "Select / move", "V", "select", true, true),
        new ToolEntry(Tool.Arrow, "Arrow", "A", "arrow", true, true),
        new ToolEntry(Tool.Line, "Line", "L", "line", true, true),
        new ToolEntry(Tool.Rect, "Rectangle", "R", "rect", true, true),
        new ToolEntry(Tool.Oval, "Oval", "O", "oval", true, true),
        new ToolEntry(Tool.Highlight, "Highlighter", "H", "highlight", true, true),
        new ToolEntry(Tool.Pen, "Pen", "P", "pen", true, true),
        new ToolEntry(Tool.Text, "Text", "T", "text", true, true),
        new ToolEntry(Tool.Counter, "Counter", "N", "counter", true, true),
        new ToolEntry(Tool.Blur, "Pixelate", "B", "pixelate", true, true),
        new ToolEntry(Tool.Spotlight, "Spotlight", "S", "spotlight", true, true),
        new ToolEntry(Tool.Magnifier, "Magnifier", "M", "magnifier", true, true),
        // Cropping in review is done by dragging the selection itself, so the
        // tool exists only where there is no selection to drag.
        new ToolEntry(Tool.Crop, "Crop", "C", "crop", true, false),
    };

    public static readonly IReadOnlyList<ActionEntry> Actions = new[]
    {
        new ActionEntry(OverlayAction.Backdrop, "Backdrop", "", "backdrop", true, true),
        new ActionEntry(OverlayAction.Color, "Annotation color", "", "color", true, true),
        new ActionEntry(OverlayAction.Undo, "Undo", "Ctrl+Z", "undo", true, true),
        new ActionEntry(OverlayAction.Redo, "Redo", "Ctrl+Y", "redo", true, true),
        new ActionEntry(OverlayAction.Copy, "Copy to clipboard", "Ctrl+C", "copy", true, true),
        new ActionEntry(OverlayAction.Save, "Save as…", "Ctrl+S", "save", true, true),
        new ActionEntry(OverlayAction.Pin, "Pin to screen", "Ctrl+P", "pin", true, true),
        new ActionEntry(OverlayAction.Ocr, "Recognize text", "", "ocr", true, true),
        new ActionEntry(OverlayAction.Translate, "Recognize + translate", "", "translate", true, true),
        // The editor IS the editor: only the review surface can open one.
        new ActionEntry(OverlayAction.OpenEditor, "Open in editor", "E", "editor", false, true),
        new ActionEntry(OverlayAction.Close, "Close", "Esc", "close", true, true),
    };

    public static IEnumerable<ToolEntry> EditorTools =>
        Entries.Where(e => e.InEditor);

    public static IEnumerable<ToolEntry> OverlayTools =>
        Entries.Where(e => e.InOverlay);

    public static IEnumerable<ActionEntry> EditorActions =>
        Actions.Where(a => a.InEditor);

    public static IEnumerable<ActionEntry> OverlayActions =>
        Actions.Where(a => a.InOverlay);

    public static ToolEntry? Entry(Tool tool)
    {
        foreach (var e in Entries) if (e.Tool == tool) return e;
        return null;
    }

    public static ActionEntry? Entry(OverlayAction action)
    {
        foreach (var a in Actions) if (a.Action == action) return a;
        return null;
    }

    /// Keyboard routing is HOST-SCOPED: a key that selects a tool the host
    /// shows no button for would leave the toolbar highlighting nothing and
    /// the user with no way back.
    public static Tool? ToolForKey(string keyLabel, bool inOverlay)
    {
        foreach (var e in Entries)
        {
            if (!string.Equals(e.KeyLabel, keyLabel, StringComparison.OrdinalIgnoreCase))
                continue;
            return (inOverlay ? e.InOverlay : e.InEditor) ? e.Tool : null;
        }
        return null;
    }
}
