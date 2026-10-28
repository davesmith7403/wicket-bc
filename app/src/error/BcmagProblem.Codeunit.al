codeunit 94102 "Bcmag Problem"
{
    // RFC 7807 Problem Details builder + the structured-failure ("Fail") helpers that
    // every operation handler uses to describe a recoverable failure. The dispatcher
    // turns a Fail object into a full Problem document and returns it at HTTP 200
    // (see BcmagRpcDispatcher — v1 transport is always-200 + complete problem body).

    procedure Build(StatusCode: Integer; ProblemType: Text; Title: Text; Detail: Text; Operation: Text; RequestId: Text; Suggest: JsonObject) Result: JsonObject
    var
        SuggestText: Text;
    begin
        Clear(Result);
        Result.Add('type', ProblemType);
        Result.Add('title', Title);
        Result.Add('status', StatusCode);
        Result.Add('detail', Detail);
        if RequestId <> '' then
            Result.Add('instance', StrSubstNo('urn:wicket:request:%1', RequestId));
        Result.Add('operation', Operation);

        Suggest.WriteTo(SuggestText);
        if SuggestText <> '{}' then
            Result.Add('suggest', Suggest);
    end;

    // Operation handlers call NewFailure/NewFailureSuggest and return false. The Fail
    // object carries {status, type, title, detail, suggest?}; the dispatcher enriches it
    // with instance (from the request id) and operation via FromFailure.
    procedure NewFailure(StatusCode: Integer; Slug: Text; Title: Text; Detail: Text) Fail: JsonObject
    var
        EmptySuggest: JsonObject;
    begin
        Fail := NewFailureSuggest(StatusCode, Slug, Title, Detail, EmptySuggest);
    end;

    procedure NewFailureSuggest(StatusCode: Integer; Slug: Text; Title: Text; Detail: Text; Suggest: JsonObject) Fail: JsonObject
    var
        SuggestText: Text;
    begin
        Clear(Fail);
        Fail.Add('status', StatusCode);
        Fail.Add('type', TypeUri(Slug));
        Fail.Add('title', Title);
        Fail.Add('detail', Detail);
        Suggest.WriteTo(SuggestText);
        if SuggestText <> '{}' then
            Fail.Add('suggest', Suggest);
    end;

    procedure FromFailure(Fail: JsonObject; Operation: Text; RequestId: Text) Result: JsonObject
    var
        Tok: JsonToken;
        Status: Integer;
        ProblemType, Title, Detail, MemberName: Text;
        Suggest: JsonObject;
    begin
        Status := 400;
        if Fail.Get('status', Tok) then Status := Tok.AsValue().AsInteger();
        if Fail.Get('type', Tok) then ProblemType := Tok.AsValue().AsText();
        if Fail.Get('title', Tok) then Title := Tok.AsValue().AsText();
        if Fail.Get('detail', Tok) then Detail := Tok.AsValue().AsText();
        if Fail.Get('suggest', Tok) then Suggest := Tok.AsObject();
        Result := Build(Status, ProblemType, Title, Detail, Operation, RequestId, Suggest);
        // RFC 7807 extension members (e.g. replay-withheld's originalStatus/reason) ride through
        // verbatim; the standard members above are owned by Build and never overwritten.
        foreach MemberName in Fail.Keys() do
            if not (MemberName in ['status', 'type', 'title', 'detail', 'suggest', 'instance', 'operation']) then begin
                Fail.Get(MemberName, Tok);
                Result.Add(MemberName, Tok);
            end;
    end;

    procedure FromError(Operation: Text; RequestId: Text) Result: JsonObject
    var
        EmptySuggest: JsonObject;
    begin
        Result := Build(500, TypeUri('internal'), 'Internal error', GetLastErrorText(), Operation, RequestId, EmptySuggest);
    end;

    procedure StatusOf(Fail: JsonObject): Integer
    var
        Tok: JsonToken;
    begin
        if Fail.Get('status', Tok) then exit(Tok.AsValue().AsInteger());
        exit(400);
    end;

    procedure ProblemTypeOf(Fail: JsonObject): Text
    var
        Tok: JsonToken;
    begin
        if Fail.Get('type', Tok) then exit(Tok.AsValue().AsText());
        exit('');
    end;

    procedure DetailOf(Fail: JsonObject): Text
    var
        Tok: JsonToken;
    begin
        if Fail.Get('detail', Tok) then exit(Tok.AsValue().AsText());
        exit('');
    end;

    procedure TypeUri(Slug: Text): Text
    begin
        exit('https://wicket.example/errors/' + Slug);
    end;
}
