codeunit 94345 "Bcmag Nested Run Probe Inner"
{
    // Inserts an Activity Log row described by args.marker (see Bcmag Nested Run Probe).

    trigger OnRun()
    var
        ActivityLog: Record "Activity Log";
        Ctx: Codeunit "Bcmag Invoke Context";
        Tok: JsonToken;
    begin
        Ctx.GetArgs().Get('marker', Tok);
        ActivityLog.Init();
        ActivityLog.Description := CopyStr(Tok.AsValue().AsText(), 1, MaxStrLen(ActivityLog.Description));
        ActivityLog.Insert(true);
    end;
}
