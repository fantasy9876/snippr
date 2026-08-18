using System.Drawing;

namespace Snippr;

/// One point on the editor's timeline: the document, the marks on it, and the
/// frame around it. All three move together, because all three are things the
/// user did.
readonly record struct EditorState(
    Bitmap Image, List<Annotation> Annotations, BackdropPreset Backdrop);
