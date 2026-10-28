codeunit 94344 "Bcmag Nested Run Probe"
{
    // Test-only action wrapper that writes through a NESTED Codeunit.Run whose return value it uses —
    // the one commit CommitBehavior cannot suppress (Business Central commits such a run on success).
    // The inner writer is Bcmag Nested Run Probe Inner, which reads the same args.

    trigger OnRun()
    var
        Ctx: Codeunit "Bcmag Invoke Context";
        Result: JsonObject;
    begin
        if Codeunit.Run(Codeunit::"Bcmag Nested Run Probe Inner") then
            Result.Add('innerRan', true)
        else
            Result.Add('innerError', GetLastErrorText());
        Ctx.SetResult(Result);
    end;
}
