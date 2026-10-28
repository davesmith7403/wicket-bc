codeunit 94157 "Bcmag Action Rollback"
{
    // Forced-rollback boundary for the `action` operation: a preview (data.preview = true) and every verb
    // enrolled with Is Mutating = false run their wrapper HERE. Bcmag Op Action calls Codeunit.Run on this
    // codeunit (a transaction boundary). OnRun runs the wrapper with explicit commits IGNORED, records that
    // the wrapper completed, then raises a sentinel error so the boundary rolls back every write. The
    // wrapper's result survives in the single-instance Bcmag Invoke Context. A wrapper error propagates
    // instead: the context is then not marked complete and GetLastErrorText carries the wrapper's message.
    //
    // CommitBehavior covers explicit Commit calls only. A nested Codeunit.Run whose return value is used
    // commits on success no matter what, and the sentinel cannot undo that. So for a non-mutating verb
    // the boundary first opens a write transaction (one row in the Execute gate, keyed by session and
    // rolled back with everything else): Business Central then refuses such a nested run outright, and
    // the verb fails instead of persisting. A preview cannot take that guard, because Business Central's
    // posting preview is itself a return-value Codeunit.Run (it always ends in an error, so it never
    // commits); a preview therefore relies on the wrapper honouring args.preview, as the companion's
    // posting wrappers do.
    Access = Public;

    var
        RollbackErr: Label 'Wicket: action ran inside a forced rollback', Locked = true;

    trigger OnRun()
    var
        InvokeContext: Codeunit "Bcmag Invoke Context";
    begin
        if InvokeContext.IsRollbackGuarded() then
            OpenWriteTransaction();
        RunWrapper(InvokeContext.GetRollbackWrapperId());
        InvokeContext.MarkRollbackCompleted();
        Error(RollbackErr);
    end;

    [CommitBehavior(CommitBehavior::Ignore)]
    local procedure RunWrapper(WrapperId: Integer)
    begin
        Codeunit.Run(WrapperId);
    end;

    // The caller holds RIMD on the gate (the role gate checked it before routing). The row never survives:
    // the sentinel error, or the wrapper's own error, rolls it back.
    local procedure OpenWriteTransaction()
    var
        ExecuteGate: Record "Bcmag Execute Gate";
    begin
        ExecuteGate.Init();
        ExecuteGate."Primary Key" := CopyStr(Format(SessionId()), 1, MaxStrLen(ExecuteGate."Primary Key"));
        ExecuteGate.Insert();
    end;
}
