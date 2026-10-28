codeunit 94300 "Bcmag Problem Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        Problem: Codeunit "Bcmag Problem";
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure BuildIncludesAllRequiredFields()
    var
        Suggest: JsonObject;
        Result: JsonObject;
        Tok: JsonToken;
    begin
        Suggest.Add('field', 'No.');
        Result := Problem.Build(400, 'https://wicket.example/errors/unknown-field',
                                'Unknown field', 'Unknown field "CustomeNo" on table 18.',
                                'query', '8e2f3c7e-5b41-4f3a-8e99-5b9e9b8f2a11', Suggest);

        LibraryAssert.IsTrue(Result.Get('type', Tok),     'type missing');
        LibraryAssert.IsTrue(Result.Get('title', Tok),    'title missing');
        LibraryAssert.IsTrue(Result.Get('status', Tok),   'status missing');
        LibraryAssert.IsTrue(Result.Get('detail', Tok),   'detail missing');
        LibraryAssert.IsTrue(Result.Get('instance', Tok), 'instance missing');
        LibraryAssert.IsTrue(Result.Get('operation', Tok),'operation missing');
        LibraryAssert.IsTrue(Result.Get('suggest', Tok),  'suggest missing');

        Result.Get('status', Tok);
        LibraryAssert.AreEqual(400, Tok.AsValue().AsInteger(), 'status mismatch');

        Result.Get('instance', Tok);
        LibraryAssert.AreEqual('urn:wicket:request:8e2f3c7e-5b41-4f3a-8e99-5b9e9b8f2a11',
                               Tok.AsValue().AsText(), 'instance not URN-shaped');
    end;

    [Test]
    procedure BuildOmitsSuggestWhenEmpty()
    var
        EmptySuggest: JsonObject;
        Result: JsonObject;
        Tok: JsonToken;
    begin
        Result := Problem.Build(404, 'x', 't', 'd', 'query', 'r-1', EmptySuggest);
        LibraryAssert.IsFalse(Result.Get('suggest', Tok), 'suggest present but empty');
    end;
}
