using System.Drawing.Drawing2D;

namespace Snippr;

/// Five-preset menu. Raises <see cref="PresetChosen"/> with
/// <c>none|ocean|sunset|mint|graphite</c>. Re-selecting the active preset
/// still raises — Honey no-ops that.
sealed class BackdropMenu : ContextMenuStrip
{
    public event EventHandler<string>? PresetChosen;
    public event EventHandler<BackdropCornerStyle>? CornerChosen;

    /// Same wording as macOS, because the two menus are the same menu as far
    /// as the person using them is concerned.
    static readonly (BackdropCornerStyle Style, string Label)[] Corners =
    [
        (BackdropCornerStyle.None, "Square corners"),
        (BackdropCornerStyle.Small, "Small corners"),
        (BackdropCornerStyle.Medium, "Medium corners"),
        (BackdropCornerStyle.Large, "Large corners"),
    ];

    static readonly (string Id, string Label, Color Swatch)[] Presets =
    [
        ("none", "None", Color.Empty),
        ("ocean", "Ocean", Color.FromArgb(0x4A, 0x7C, 0xF0)),
        ("sunset", "Sunset", Color.FromArgb(0xFF, 0x7E, 0x4A)),
        ("mint", "Mint", Color.FromArgb(0x3D, 0xDC, 0xB0)),
        ("graphite", "Graphite", Color.FromArgb(0x34, 0x3A, 0x46)),
    ];

    string _active = "none";
    readonly List<ToolStripMenuItem> _presetItems = new();
    readonly List<ToolStripMenuItem> _cornerItems = new();

    public BackdropMenu()
    {
        Renderer = new ToolbarRenderer();
        Font = Theme.MenuFont;
        BackColor = Theme.ChromeRaised;
        ForeColor = Theme.Icon;
        ShowImageMargin = true;
        ImageScalingSize = new Size(16, 12);
        foreach (var (id, label, swatch) in Presets)
        {
            var item = new ToolStripMenuItem(label)
            {
                Tag = id,
                Image = SwatchBitmap(id, swatch),
            };
            item.Click += (_, _) =>
            {
                HoverHintOf();
                PresetChosen?.Invoke(this, id);
            };
            Items.Add(item);
            _presetItems.Add(item);
        }
        // The corner choice belongs in the SAME menu as the preset — it is a
        // property of the frame, and someone looking for it looks here before
        // they look in Settings. macOS has had this since 1.2.11; Windows had
        // the setting and no way to reach it.
        Items.Add(new ToolStripSeparator());
        foreach (var (style, label) in Corners)
        {
            var item = new ToolStripMenuItem(label) { Tag = style };
            item.Click += (_, _) =>
            {
                HoverHintOf();
                CornerChosen?.Invoke(this, style);
            };
            Items.Add(item);
            _cornerItems.Add(item);
        }
        Opening += (_, _) =>
        {
            HoverHintOf();
            SetActiveCorner(AppSettings.Current.CornerStyle);
            SizeItems();
        };
    }

    /// Every row gets the same box: the natural width the label needs, and a
    /// taller-than-default height so the swatch has room.
    ///
    /// The width has to be MEASURED. Fixing `AutoSize = false` with only a
    /// height left every row at `ToolStripMenuItem`'s default width, and once
    /// the image margin took its share there was no room left to draw the
    /// label in — the menu showed five swatches and no words. Measuring on
    /// `Opening` rather than in the constructor also means the row is right on
    /// the display the menu actually opens on, not the one the app started on.
    void SizeItems()
    {
        int width = 0;
        foreach (ToolStripItem item in Items)
        {
            if (item is ToolStripSeparator) continue;
            item.AutoSize = true;
            width = Math.Max(width, item.GetPreferredSize(Size.Empty).Width);
        }
        int height = Theme.Px(28, DeviceDpi);
        foreach (ToolStripItem item in Items)
        {
            // Separators keep their own (thin) height — forcing a row height
            // on one turns the divider into a gap the size of a menu row.
            if (item is ToolStripSeparator) continue;
            item.AutoSize = false;
            item.Size = new Size(width, height);
        }
    }

    /// Runs the real `Opening` handlers without putting a dropdown on the
    /// screen, so the smoke can check that opening the menu is what sizes the
    /// rows — not merely that the sizer works when called directly.
    internal void RaiseOpeningForTesting() =>
        OnOpening(new System.ComponentModel.CancelEventArgs());

    public void SetActive(string id)
    {
        _active = id;
        // Only the preset rows: iterating every item would untick the corner
        // rows, whose Tag is a style rather than an id.
        foreach (var item in _presetItems)
            item.Checked = Equals(item.Tag as string, id);
    }

    public void SetActiveCorner(BackdropCornerStyle style)
    {
        foreach (var item in _cornerItems)
            item.Checked = item.Tag is BackdropCornerStyle s && s == style;
    }

    public string Active => _active;

    static void HoverHintOf()
    {
        foreach (Form f in Application.OpenForms)
            if (f is HoverHint hint) hint.HideNow();
    }

    static Bitmap SwatchBitmap(string id, Color color)
    {
        var bmp = new Bitmap(16, 12);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Color.Transparent);
        if (id == "none")
        {
            using var fill = new SolidBrush(Theme.Chrome);
            using var border = new Pen(Theme.Hairline);
            g.FillRectangle(fill, 0, 0, 15, 11);
            g.DrawRectangle(border, 0, 0, 15, 11);
        }
        else
        {
            using var fill = new SolidBrush(color);
            g.FillRectangle(fill, 0, 0, 16, 12);
        }
        return bmp;
    }
}
