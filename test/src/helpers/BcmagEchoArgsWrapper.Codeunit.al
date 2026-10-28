codeunit 94341 "Bcmag Echo Args Wrapper"
{
    // Test-only action/invoke wrapper: returns exactly the args the framework handed it, so a test can
    // see what the op layer merged in (target.systemId, the forced preview flag) — the Ping sample only
    // echoes one member.

    trigger OnRun()
    var
        Ctx: Codeunit "Bcmag Invoke Context";
        Args, Echo: JsonObject;
        Serialized: Text;
    begin
        Args := Ctx.GetArgs();
        Args.WriteTo(Serialized);
        Echo.ReadFrom(Serialized);
        Ctx.SetResult(Echo);
    end;
}
