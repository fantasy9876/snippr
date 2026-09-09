namespace Snippr;

/// Session-stop table for scrolling capture. Shared with the parity gate so
/// Esc=cancel / Enter=finish / Ctrl+C=quickcopy cannot drift from macOS 1.2.22
/// without a red gate (Honey H2). Platform-free on purpose: numbers and
/// strings only — WinForms wiring stays in `ScrollShot.cs`.
public enum ScrollStopAction
{
    Cancel,
    Finish,
    QuickCopy,
}

public struct ScrollStopFlags
{
    public bool Finished;
    public bool Cancelled;
    public bool QuickCopy;
}

public readonly struct ScrollFinishActions
{
    public ScrollFinishActions(bool copy, bool show, bool save)
    {
        Copy = copy;
        Show = show;
        Save = save;
    }

    public bool Copy { get; }
    public bool Show { get; }
    public bool Save { get; }
}

public static class ScrollSessionStop
{
    public const int EscId = 1000;
    public const int ReturnId = 1001;
    public const int CopyId = 1002;

    public const uint ModNone = 0;
    public const uint ModControl = 0x0002;
    public const uint ModShift = 0x0004;
    public const uint ModAlt = 0x0001;

    public const uint VkEscape = 0x1B;
    public const uint VkReturn = 0x0D;
    public const uint VkC = 0x43;

    /// Physical key → hotkey ID for the live scroll session. `installStop`
    /// registers exactly this table; the parity gate reads it so swapping
    /// Esc/Return IDs cannot hide behind the handler seam.
    public static readonly (uint Vk, uint Mods, int Id)[] Specs =
    {
        (VkEscape, ModNone, EscId),
        (VkReturn, ModNone, ReturnId),
        (VkC, ModControl, CopyId),
    };

    public static ScrollStopAction? ForHotkeyId(int id) => id switch
    {
        EscId => ScrollStopAction.Cancel,
        ReturnId => ScrollStopAction.Finish,
        CopyId => ScrollStopAction.QuickCopy,
        _ => null,
    };

    public static ScrollStopAction? ForKey(uint vk, uint mods)
    {
        foreach (var spec in Specs)
        {
            if (spec.Vk == vk && spec.Mods == mods)
                return ForHotkeyId(spec.Id);
        }
        return null;
    }

    public static void Apply(ScrollStopAction action, ref ScrollStopFlags flags)
    {
        switch (action)
        {
            case ScrollStopAction.Cancel:
                flags.Cancelled = true;
                flags.Finished = true;
                break;
            case ScrollStopAction.Finish:
                flags.Finished = true;
                break;
            case ScrollStopAction.QuickCopy:
                flags.QuickCopy = true;
                flags.Finished = true;
                break;
        }
    }

    /// Snapshot-at-begin routing. QuickCopy forces copy and skips the editor;
    /// afterSave stays whatever the session captured at begin(). Cancel is
    /// not this function — it does not present.
    public static ScrollFinishActions EffectiveActions(
        bool quickCopy, bool afterCopy, bool afterShow, bool afterSave)
    {
        if (quickCopy)
            return new ScrollFinishActions(copy: true, show: false, save: afterSave);
        return new ScrollFinishActions(afterCopy, afterShow, afterSave);
    }

    public static string SessionStopHint(bool hotkeysRegistered) =>
        hotkeysRegistered
            ? "Enter/✓ xong · Ctrl+C copy · Esc hủy"
            : "bấm ✓ để xong";

    /// Do not prefix with "xong " — that sat next to "Esc hủy" and read as
    /// if Esc still finished the capture (macOS H3).
    public static string StitchingProgressText(int pixels, bool hotkeysRegistered) =>
        $"Đã ghép {pixels}px — cuộn tiếp · " + SessionStopHint(hotkeysRegistered);
}
