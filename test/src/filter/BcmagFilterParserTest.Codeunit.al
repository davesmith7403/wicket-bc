codeunit 94307 "Bcmag Filter Parser Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        Lexer: Codeunit "Bcmag Filter Lexer";
        Parser: Codeunit "Bcmag Filter Parser";
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure ParsesSimpleEquality()
    var
        Tokens: JsonArray;
        Ast: JsonObject;
        Err: Text;
        Tok: JsonToken;
    begin
        LibraryAssert.IsTrue(Lexer.Tokenize('Name eq ''Acme''', Tokens, Err), Err);
        LibraryAssert.IsTrue(Parser.Parse(Tokens, Ast, Err), Err);
        Ast.Get('node', Tok);
        LibraryAssert.AreEqual('binop', Tok.AsValue().AsText(), 'expected binop');
        Ast.Get('op', Tok);
        LibraryAssert.AreEqual('eq', Tok.AsValue().AsText(), 'expected eq');
    end;

    [Test]
    procedure ParsesAndPrecedenceCorrectly()
    var
        Tokens: JsonArray;
        Ast: JsonObject;
        Err: Text;
        Tok: JsonToken;
    begin
        // (A=1) and (B=2) or (C=3)  →  ((A and B) or C)
        LibraryAssert.IsTrue(Lexer.Tokenize('A eq 1 and B eq 2 or C eq 3', Tokens, Err), Err);
        LibraryAssert.IsTrue(Parser.Parse(Tokens, Ast, Err), Err);
        Ast.Get('op', Tok);
        LibraryAssert.AreEqual('or', Tok.AsValue().AsText(), 'top-level should be or');
    end;

    [Test]
    procedure ParsesStartsWith()
    var
        Tokens: JsonArray;
        Ast: JsonObject;
        Err: Text;
        Tok: JsonToken;
    begin
        LibraryAssert.IsTrue(Lexer.Tokenize('startswith(Name, ''Ac'')', Tokens, Err), Err);
        LibraryAssert.IsTrue(Parser.Parse(Tokens, Ast, Err), Err);
        Ast.Get('node', Tok);
        LibraryAssert.AreEqual('func', Tok.AsValue().AsText(), 'expected func node');
    end;

    [Test]
    procedure ParsesIn()
    var
        Tokens: JsonArray;
        Ast: JsonObject;
        Err: Text;
        Tok: JsonToken;
        Values: JsonArray;
    begin
        LibraryAssert.IsTrue(Lexer.Tokenize('"No." in (''A'', ''B'', ''C'')', Tokens, Err), Err);
        LibraryAssert.IsTrue(Parser.Parse(Tokens, Ast, Err), Err);
        Ast.Get('node', Tok);
        LibraryAssert.AreEqual('in', Tok.AsValue().AsText(), 'expected in');
        Ast.Get('values', Tok);
        Values := Tok.AsArray();
        LibraryAssert.AreEqual(3, Values.Count(), 'expected 3 values');
    end;

    [Test]
    procedure ParsesBoolLiteralTrue()
    var
        Tokens: JsonArray;
        Ast: JsonObject;
        Err: Text;
    begin
        LibraryAssert.IsTrue(Lexer.Tokenize('Blocked eq true', Tokens, Err), Err);
        LibraryAssert.IsTrue(Parser.Parse(Tokens, Ast, Err), Err);
        LibraryAssert.AreEqual('bool', AstValuePart(Ast, 'kind'), 'value kind');
        LibraryAssert.AreEqual('true', AstValuePart(Ast, 'value'), 'value text');
    end;

    [Test]
    procedure ParsesBoolLiteralCaseInsensitively()
    var
        Tokens: JsonArray;
        Ast: JsonObject;
        Err: Text;
    begin
        // OData keywords are case-insensitive; the AST value is normalised to lowercase.
        LibraryAssert.IsTrue(Lexer.Tokenize('Blocked ne FALSE', Tokens, Err), Err);
        LibraryAssert.IsTrue(Parser.Parse(Tokens, Ast, Err), Err);
        LibraryAssert.AreEqual('bool', AstValuePart(Ast, 'kind'), 'value kind');
        LibraryAssert.AreEqual('false', AstValuePart(Ast, 'value'), 'value text');
    end;

    [Test]
    procedure CarriesUnescapedStringThroughAst()
    var
        Tokens: JsonArray;
        Ast: JsonObject;
        Err: Text;
    begin
        // Filter text: Name eq 'O''Brien' — the AST carries the unescaped value.
        LibraryAssert.IsTrue(Lexer.Tokenize('Name eq ''O''''Brien''', Tokens, Err), Err);
        LibraryAssert.IsTrue(Parser.Parse(Tokens, Ast, Err), Err);
        LibraryAssert.AreEqual('string', AstValuePart(Ast, 'kind'), 'value kind');
        LibraryAssert.AreEqual('O''Brien', AstValuePart(Ast, 'value'), 'value text');
    end;

    [Test]
    procedure RejectsBoolLiteralInFunction()
    var
        Tokens: JsonArray;
        Ast: JsonObject;
        Err: Text;
    begin
        // Bool literals are valid only as comparison values, not as function arguments.
        LibraryAssert.IsTrue(Lexer.Tokenize('startswith(Name, true)', Tokens, Err), Err);
        LibraryAssert.IsFalse(Parser.Parse(Tokens, Ast, Err), 'should fail');
    end;

    [Test]
    procedure RejectsBoolLiteralInInList()
    var
        Tokens: JsonArray;
        Ast: JsonObject;
        Err: Text;
    begin
        LibraryAssert.IsTrue(Lexer.Tokenize('Blocked in (true, false)', Tokens, Err), Err);
        LibraryAssert.IsFalse(Parser.Parse(Tokens, Ast, Err), 'should fail');
    end;

    [Test]
    procedure StillRejectsBareIdentAsValue()
    var
        Tokens: JsonArray;
        Ast: JsonObject;
        Err: Text;
    begin
        // Only true/false get literal treatment; other idents in value position stay invalid.
        LibraryAssert.IsTrue(Lexer.Tokenize('Name eq Foo', Tokens, Err), Err);
        LibraryAssert.IsFalse(Parser.Parse(Tokens, Ast, Err), 'should fail');
    end;

    local procedure AstValuePart(Ast: JsonObject; Part: Text): Text
    var
        Tok: JsonToken;
        ValueNode: JsonObject;
    begin
        Ast.Get('value', Tok);
        ValueNode := Tok.AsObject();
        ValueNode.Get(Part, Tok);
        exit(Tok.AsValue().AsText());
    end;

    [Test]
    procedure RejectsInListMissingComma()
    var
        Tokens: JsonArray;
        Ast: JsonObject;
        Err: Text;
    begin
        // ('a' 'b') used to parse as two members; a malformed list must not be guessed at.
        LibraryAssert.IsTrue(Lexer.Tokenize('"No." in (''A'' ''B'')', Tokens, Err), Err);
        LibraryAssert.IsFalse(Parser.Parse(Tokens, Ast, Err), 'missing comma should fail');
    end;

    [Test]
    procedure RejectsInListTrailingComma()
    var
        Tokens: JsonArray;
        Ast: JsonObject;
        Err: Text;
    begin
        LibraryAssert.IsTrue(Lexer.Tokenize('"No." in (''A'',)', Tokens, Err), Err);
        LibraryAssert.IsFalse(Parser.Parse(Tokens, Ast, Err), 'trailing comma should fail');
    end;

    [Test]
    procedure RejectsNullInInList()
    var
        Tokens: JsonArray;
        Ast: JsonObject;
        Err: Text;
    begin
        LibraryAssert.IsTrue(Lexer.Tokenize('"No." in (''A'', null)', Tokens, Err), Err);
        LibraryAssert.IsFalse(Parser.Parse(Tokens, Ast, Err), 'null member should fail');
        LibraryAssert.IsTrue(StrPos(Err, 'eq null') > 0, 'the error points at "eq null"');
    end;

    [Test]
    procedure StillParsesSingleMemberInList()
    var
        Tokens: JsonArray;
        Ast: JsonObject;
        Err: Text;
    begin
        LibraryAssert.IsTrue(Lexer.Tokenize('"No." in (''A'')', Tokens, Err), Err);
        LibraryAssert.IsTrue(Parser.Parse(Tokens, Ast, Err), Err);
    end;
}
