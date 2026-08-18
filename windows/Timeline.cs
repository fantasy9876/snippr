namespace Snippr;

/// One undo/redo timeline, and the rules that go with it.
///
/// Separated from the editor for two reasons. It is the rule set that decides
/// whether a backdrop preset is "one step" or a parallel history — on macOS
/// the answer had to be ONE timeline, or undo after mark→preset→mark walked
/// the two stacks in an order the user never performed. And it holds no
/// drawing types, so the headless parity gate can exercise those rules on any
/// machine, while the editor's own wiring is checked where GDI+ lives.
///
/// `Push` is called BEFORE a mutation, with the state as it is about to stop
/// being: that is what makes an edit and its undo the same size.
sealed class Timeline<TState>
{
    readonly Stack<TState> _undo = new();
    readonly Stack<TState> _redo = new();

    /// Called with every state that leaves the timeline for good, so an owner
    /// holding unmanaged resources (a bitmap, say) can release the ones no
    /// longer reachable. It is never called for a state that is merely moving
    /// between the two stacks.
    public Action<IReadOnlyList<TState>>? Discarding { get; set; }

    public bool CanUndo => _undo.Count > 0;
    public bool CanRedo => _redo.Count > 0;
    public int UndoDepth => _undo.Count;
    public int RedoDepth => _redo.Count;

    /// A new edit FORKS the history: everything that had been undone is now
    /// unreachable, because the user built a different future.
    public void Push(TState current)
    {
        _undo.Push(current);
        if (_redo.Count == 0) return;
        var dropped = _redo.ToArray();
        _redo.Clear();
        Discarding?.Invoke(dropped);
    }

    public bool TryUndo(TState current, out TState previous)
    {
        if (_undo.Count == 0) { previous = default!; return false; }
        _redo.Push(current);
        previous = _undo.Pop();
        return true;
    }

    public bool TryRedo(TState current, out TState next)
    {
        if (_redo.Count == 0) { next = default!; return false; }
        _undo.Push(current);
        next = _redo.Pop();
        return true;
    }

    public void Clear()
    {
        var dropped = _undo.Concat(_redo).ToArray();
        _undo.Clear();
        _redo.Clear();
        if (dropped.Length > 0) Discarding?.Invoke(dropped);
    }
}
