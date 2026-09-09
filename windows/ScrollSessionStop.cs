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

    public const int VkShift = 0x10;
    public const int VkControl = 0x11;
    public const int VkMenu = 0x12;
}

/// Production stop path. `ScrollShot.ApplyStop` is a thin marshal onto
/// `ApplyStop` here; the parity gate drives this object so W2 (Finished=true
/// without `Apply`) cannot stay green. Snapshot-at-begin lives on the machine
/// so Route() matches TrayContext.
public sealed class ScrollStopMachine
{
    ScrollStopFlags _flags;
    public ScrollStopFlags Flags => _flags;
    public bool AfterCopy { get; }
    public bool AfterShow { get; }
    public bool AfterSave { get; }

    public ScrollStopMachine(bool afterCopy, bool afterShow, bool afterSave)
    {
        AfterCopy = afterCopy;
        AfterShow = afterShow;
        AfterSave = afterSave;
    }

    /// Returns false when the session already ended (second key is ignored).
    public bool ApplyStop(ScrollStopAction action)
    {
        if (_flags.Finished) return false;
        ScrollSessionStop.Apply(action, ref _flags);
        return true;
    }

    public bool ShouldCompose => _flags.Finished && !_flags.Cancelled;

    public ScrollFinishActions? Route() =>
        Present(_flags, AfterCopy, AfterShow, AfterSave);

    public static ScrollFinishActions? Present(
        ScrollStopFlags flags, bool afterCopy, bool afterShow, bool afterSave)
    {
        if (!flags.Finished || flags.Cancelled) return null;
        return ScrollSessionStop.EffectiveActions(
            flags.QuickCopy, afterCopy, afterShow, afterSave);
    }
}

/// Dispatch helper. LL hook must marshal (`true`); timer / ✓ / WM_HOTKEY run
/// inline (`false`). Do not infer from `SynchronizationContext.Current` — the
/// hook proc runs on the installing (UI) thread, so that check is always true
/// and End() would run inside the hook (Honey W-H3).
public static class ScrollStopInvoke
{
    public const bool HookMarshals = true;
    public const bool UiMarshals = false;

    public static void Run(bool marshal, SynchronizationContext? sync, Action go)
    {
        if (marshal && sync != null) sync.Post(_ => go(), null);
        else go();
    }

    public static Action<ScrollStopAction> Bind(
        Action<ScrollStopAction, bool> apply, bool marshal)
        => action => apply(action, marshal);
}

/// LL-hook policy. Only specs that failed `RegisterHotKey` are hooked, and
/// modifiers come from a physical-state reader (`GetAsyncKeyState`), not the
/// installing thread's message queue (`GetKeyState`).
public static class ScrollStopHookPolicy
{
    public static uint ModsFromKeyState(Func<int, short> getKey)
    {
        uint mods = 0;
        if ((getKey(ScrollSessionStop.VkControl) & 0x8000) != 0)
            mods |= ScrollSessionStop.ModControl;
        if ((getKey(ScrollSessionStop.VkShift) & 0x8000) != 0)
            mods |= ScrollSessionStop.ModShift;
        if ((getKey(ScrollSessionStop.VkMenu) & 0x8000) != 0)
            mods |= ScrollSessionStop.ModAlt;
        return mods;
    }

    public static int[] FailedSpecIds(IReadOnlyCollection<int> registeredIds)
    {
        var failed = new List<int>();
        foreach (var spec in ScrollSessionStop.Specs)
        {
            bool registered = false;
            foreach (var id in registeredIds)
            {
                if (id == spec.Id) { registered = true; break; }
            }
            if (!registered) failed.Add(spec.Id);
        }
        return failed.ToArray();
    }

    /// Null unless this chord belongs to a spec we were asked to hook.
    public static ScrollStopAction? Interpret(
        uint vk, uint mods, IReadOnlyCollection<int> hookedIds)
    {
        foreach (var spec in ScrollSessionStop.Specs)
        {
            if (spec.Vk != vk || spec.Mods != mods) continue;
            foreach (var id in hookedIds)
            {
                if (id == spec.Id) return ScrollSessionStop.ForHotkeyId(spec.Id);
            }
        }
        return null;
    }
}
