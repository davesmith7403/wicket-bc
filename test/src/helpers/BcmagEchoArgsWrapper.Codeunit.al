codeunit 94341 "Bcmag Echo Args Wrapper"
{
    // Test-only action/invoke wrapper: returns exactly the args the framework handed it, so a test can
    // see what the op layer merged in (target.systemId, the forced preview flag) — the Ping sample only
    // echoes one member. args.noResult = true: return nothing, like a wrapper that sets no result.

    trigger OnRun()
    var
        Ctx: Codeunit "Bcmag Invoke Context";
        Args, Echo: JsonObject;
        Tok: JsonToken;
        Serialized: Text;
    begin
        Args := Ctx.GetArgs();
        if Args.Get('noResult', Tok) then
            if Tok.AsValue().AsBoolean() then
                exit;
        Args.WriteTo(Serialized);
        Echo.ReadFrom(Serialized);
        Ctx.SetResult(Echo);
    end;
}
