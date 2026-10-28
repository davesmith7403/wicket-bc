codeunit 94342 "Bcmag Rollback Probe Wrapper"
{
    // Test-only action wrapper that WRITES: inserts an Activity Log row described by args.marker, then
    // optionally commits (args.commit) and optionally fails afterwards (args.failAfterWrite). The forced
    // rollback tests read the table back to prove what persisted.

    trigger OnRun()
    var
        ActivityLog: Record "Activity Log";
        Ctx: Codeunit "Bcmag Invoke Context";
        Args, Result : JsonObject;
        Tok: JsonToken;
        Marker: Text;
    begin
        Args := Ctx.GetArgs();
        Args.Get('marker', Tok);
        Marker := Tok.AsValue().AsText();
        ActivityLog.Init();
        ActivityLog.Description := CopyStr(Marker, 1, MaxStrLen(ActivityLog.Description));
        ActivityLog.Insert(true);
        if Args.Get('commit', Tok) then
            if Tok.AsValue().AsBoolean() then
                Commit();
        if Args.Get('failAfterWrite', Tok) then
            if Tok.AsValue().AsBoolean() then
                Error('probe failed after writing %1', Marker);
        Result.Add('wrote', Marker);
        Ctx.SetResult(Result);
    end;
}
