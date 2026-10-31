codeunit 94161 "Bcmag Batch Rollback"
{
    // Forced-rollback boundary for a batch preview: Bcmag Op Batch calls Codeunit.Run on this codeunit (a
    // transaction boundary). OnRun runs every item, keeps the results or the failing item's problem in the
    // single-instance Bcmag Batch Context, then raises a sentinel error so the boundary rolls back every
    // write the items made — their change history entries included.
    Access = Internal;

    var
        RollbackErr: Label 'Wicket: batch preview ran inside a forced rollback', Locked = true;

    trigger OnRun()
    var
        Ctx: Codeunit "Bcmag Batch Context";
        OpBatch: Codeunit "Bcmag Op Batch";
        Results: JsonArray;
        Fail: JsonObject;
    begin
        if OpBatch.RunItems(Ctx.GetItems(), Results, Fail) then
            Ctx.SetCompleted(Results)
        else
            Ctx.SetFailed(Fail);
        Error(RollbackErr);
    end;
}
