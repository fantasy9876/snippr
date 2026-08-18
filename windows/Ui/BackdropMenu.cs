using System.Drawing.Drawing2D;

namespace Snippr;

/// Five-preset menu. Raises <see cref="PresetChosen"/> with
/// <c>none|ocean|sunset|mint|graphite</c>. Re-selecting the active preset
/// still raises — Honey no-ops that.
sealed class BackdropMenu : ContextMenuStrip
{
    public event EventHandler<string>? PresetChosen;

    static readonly (string Id, string Label, Color Swatch)[] Presets =
    [
        ("none", "None", Color.Empty),
        ("ocean", "Ocean", Color.FromArgb(0x4A, 0x7C, 0xF0)),
        ("sunset", "Sunset", Color.FromArgb(0xFF, 0x7E, 0x4A)),
        ("mint", "Mint", Color.FromArgb(0x3D, 0xDC, 0xB0)),
        ("graphite", "Graphite", Color.FromArgb(0x34, 0x3A, 0x46)),
    ];

    string _active = "none";

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
                AutoSize = false,
                Height = 28,
                Image = SwatchBitmap(id, swatch),
            };
            item.Click += (_, _) =>
            {
                HoverHintOf();
                PresetChosen?.Invoke(this, id);
            };
            Items.Add(item);
        }
        Opening += (_, _) => HoverHintOf();
    }

    public void SetActive(string id)
    {
        _active = id;
        foreach (ToolStripItem item in Items)
            if (item is ToolStripMenuItem mi)
                mi.Checked = Equals(mi.Tag as string, id);
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
