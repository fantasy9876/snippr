using System.Drawing.Drawing2D;

namespace Snippr;

/// Tag a <see cref="ToolStripItem"/> with this so the renderer draws the
/// vector icon at the item's live size (sharp at every DPI).
readonly record struct IconRef(string Key, Color? Tint = null);

sealed class ToolbarRenderer : ToolStripProfessionalRenderer
{
    public ToolbarRenderer() : base(new DarkColorTable()) { }

    protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e)
    {
        using var brush = new SolidBrush(Theme.Chrome);
        e.Graphics.FillRectangle(brush, e.AffectedBounds);
    }

    protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e) { }

    protected override void OnRenderButtonBackground(ToolStripItemRenderEventArgs e)
    {
        if (e.Item is not ToolStripButton b) return;
        Color? fill = b.Pressed ? Theme.Pressed
            : b.Checked ? Theme.Selected
            : b.Selected ? Theme.Hover
            : null;
        if (fill is null) return;
        var r = new Rectangle(Point.Empty, e.Item.Size);
        r.Inflate(-1, -2);
        using var path = Round(r, Theme.PxF(Theme.RadiusBtn, e.ToolStrip?.DeviceDpi ?? 96));
        using var brush = new SolidBrush(fill.Value);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        e.Graphics.FillPath(brush, path);
    }

    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e)
    {
        using var pen = new Pen(Theme.Hairline);
        if (e.Vertical)
        {
            int x = e.Item.Width / 2;
            e.Graphics.DrawLine(pen, x, 6, x, e.Item.Height - 6);
        }
        else
        {
            int y = e.Item.Height / 2;
            e.Graphics.DrawLine(pen, 6, y, e.Item.Width - 6, y);
        }
    }

    protected override void OnRenderItemImage(ToolStripItemImageRenderEventArgs e)
    {
        if (e.Item.Tag is not IconRef icon)
        {
            base.OnRenderItemImage(e);
            return;
        }
        var dest = e.ImageRectangle;
        if (dest.Width <= 0 || dest.Height <= 0)
        {
            int side = Math.Min(e.Item.Height, e.Item.Width) - 8;
            dest = new Rectangle((e.Item.Width - side) / 2, (e.Item.Height - side) / 2, side, side);
        }
        Color color = icon.Tint
            ?? (e.Item is ToolStripButton { Checked: true } ? Theme.Accent : Theme.Icon);
        Icons.Draw(e.Graphics, icon.Key, dest, color);
    }

    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
    {
        e.TextColor = e.Item.ForeColor == Theme.IconMuted ? Theme.IconMuted : Theme.Icon;
        base.OnRenderItemText(e);
    }

    static GraphicsPath Round(Rectangle r, float radius)
    {
        var path = new GraphicsPath();
        if (r.Width <= 0 || r.Height <= 0) return path;
        float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    sealed class DarkColorTable : ProfessionalColorTable
    {
        public override Color ToolStripGradientBegin => Theme.Chrome;
        public override Color ToolStripGradientMiddle => Theme.Chrome;
        public override Color ToolStripGradientEnd => Theme.Chrome;
        public override Color ImageMarginGradientBegin => Theme.Chrome;
        public override Color ImageMarginGradientMiddle => Theme.Chrome;
        public override Color ImageMarginGradientEnd => Theme.Chrome;
        public override Color SeparatorDark => Theme.Hairline;
        public override Color SeparatorLight => Theme.Hairline;
    }
}
