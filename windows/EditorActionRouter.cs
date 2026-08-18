namespace Snippr;

/// Which actions the editor's toolbar actually does something with.
///
/// This exists because the catalog said the editor had a Backdrop button long
/// before one existed: the tool row was built from the table, the action row
/// was a hand-written list, and a gate that only reads the table cannot see a
/// button that was never made. Both the toolbar and the click handler go
/// through this, so "the catalog offers it" and "the editor handles it" are
/// the same statement.
static class EditorActionRouter
{
    public static bool IsHandled(OverlayAction action) => action switch
    {
        OverlayAction.Backdrop or OverlayAction.Color
            or OverlayAction.Undo or OverlayAction.Redo
            or OverlayAction.Copy or OverlayAction.Save or OverlayAction.Pin
            or OverlayAction.Ocr or OverlayAction.Translate
            or OverlayAction.Close => true,
        // The editor cannot open itself.
        OverlayAction.OpenEditor => false,
        // An action added to the enum and forgotten here must FAIL, loudly, in
        // the gate — silently answering "the editor does not handle it" is the
        // exact shape of the missing Backdrop button.
        _ => throw new ArgumentOutOfRangeException(nameof(action), action, null),
    };
}
