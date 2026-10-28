codeunit 94190 "Bcmag Wrap Ping"
{
    // Reference wrapper showing the invoke pattern. It is NOT auto-enrolled (deny-by-default):
    // an admin enrolls it by adding a Wicket Procedure Catalog row
    //   { Logical Codeunit Id = 94190, Procedure Name = 'Ping', Wrapper Codeunit Id = 94190,
    //     Return Shape = json, Allow Run = true }
    // and exposing codeunit 94190 for invoke. Then:
    //   invoke { codeunitId: 94190, procedure: 'Ping', args: { message: 'hi' } }

    trigger OnRun()
    var
        Ctx: Codeunit "Bcmag Invoke Context";
        Args, Result: JsonObject;
        Tok: JsonToken;
        Message: Text;
    begin
        Args := Ctx.GetArgs();
        if Args.Get('message', Tok) then
            Message := Tok.AsValue().AsText();

        Result.Add('pong', true);
        if Message <> '' then
            Result.Add('echo', Message);
        Result.Add('serverTime', Format(CurrentDateTime(), 0, 9));
        Result.Add('company', CompanyName());
        Ctx.SetResult(Result);
    end;
}
