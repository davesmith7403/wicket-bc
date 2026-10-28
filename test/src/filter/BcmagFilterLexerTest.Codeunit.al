codeunit 94306 "Bcmag Filter Lexer Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        Lexer: Codeunit "Bcmag Filter Lexer";
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure TokenizesSimpleEquality()
    var
        Tokens: JsonArray;
        Err: Text;
    begin
        LibraryAssert.IsTrue(Lexer.Tokenize('Name eq ''Acme''', Tokens, Err), Err);
        LibraryAssert.AreEqual(3, Tokens.Count(), 'expected 3 tokens (ident, op, string)');
    end;

    [Test]
    procedure TokenizesQuotedNameWithSpaces()
    var
        Tokens: JsonArray;
        Err: Text;
        First: JsonToken;
        Obj: JsonObject;
        Tok: JsonToken;
    begin
        LibraryAssert.IsTrue(Lexer.Tokenize('"Customer Posting Group" eq ''DOMESTIC''', Tokens, Err), Err);
        Tokens.Get(0, First);
        Obj := First.AsObject();
        Obj.Get('value', Tok);
        LibraryAssert.AreEqual('Customer Posting Group', Tok.AsValue().AsText(), 'identifier value');
    end;

    [Test]
    procedure TokenizesNumberAndDate()
    var
        Tokens: JsonArray;
        Err: Text;
    begin
        LibraryAssert.IsTrue(Lexer.Tokenize('Balance gt 1000 and "Posting Date" ge 2026-05-08', Tokens, Err), Err);
        LibraryAssert.AreEqual(7, Tokens.Count(), 'expected 7 tokens');
    end;

    [Test]
    procedure RejectsUnterminatedString()
    var
        Tokens: JsonArray;
        Err: Text;
    begin
        LibraryAssert.IsFalse(Lexer.Tokenize('Name eq ''Acme', Tokens, Err), 'should fail');
    end;

    [Test]
    procedure UnescapesDoubledApostrophe()
    var
        Tokens: JsonArray;
        Err: Text;
    begin
        // Filter text: Name eq 'O''Brien'
        LibraryAssert.IsTrue(Lexer.Tokenize(StrSubstNo('Name eq %1O%1%1Brien%1', Apo()), Tokens, Err), Err);
        LibraryAssert.AreEqual(3, Tokens.Count(), 'expected 3 tokens');
        LibraryAssert.AreEqual('string', TokenKind(Tokens, 2), 'literal kind');
        LibraryAssert.AreEqual('O''Brien', TokenValue(Tokens, 2), 'value must be unescaped');
    end;

    [Test]
    procedure UnescapesStringEndingInEscapedQuote()
    var
        Tokens: JsonArray;
        Err: Text;
    begin
        // Filter text: Name eq 'x'''  (value x')
        LibraryAssert.IsTrue(Lexer.Tokenize(StrSubstNo('Name eq %1x%1%1%1', Apo()), Tokens, Err), Err);
        LibraryAssert.AreEqual('x''', TokenValue(Tokens, 2), 'trailing escaped quote');
    end;

    [Test]
    procedure UnescapesStringOfOnlyEscapedQuote()
    var
        Tokens: JsonArray;
        Err: Text;
    begin
        // Filter text: Name eq ''''  (value is one apostrophe)
        LibraryAssert.IsTrue(Lexer.Tokenize(StrSubstNo('Name eq %1%1%1%1', Apo()), Tokens, Err), Err);
        LibraryAssert.AreEqual('string', TokenKind(Tokens, 2), 'literal kind');
        LibraryAssert.AreEqual('''', TokenValue(Tokens, 2), 'single apostrophe value');
    end;

    [Test]
    procedure UnescapesMultipleEscapedQuotes()
    var
        Tokens: JsonArray;
        Err: Text;
    begin
        // Filter text: Name eq 'a''b''c'  (value a'b'c)
        LibraryAssert.IsTrue(Lexer.Tokenize(StrSubstNo('Name eq %1a%1%1b%1%1c%1', Apo()), Tokens, Err), Err);
        LibraryAssert.AreEqual('a''b''c', TokenValue(Tokens, 2), 'multiple escaped quotes');
    end;

    [Test]
    procedure StillTokenizesEmptyString()
    var
        Tokens: JsonArray;
        Err: Text;
    begin
        // Filter text: Name eq ''  (empty value, not an escape)
        LibraryAssert.IsTrue(Lexer.Tokenize(StrSubstNo('Name eq %1%1', Apo()), Tokens, Err), Err);
        LibraryAssert.AreEqual(3, Tokens.Count(), 'expected 3 tokens');
        LibraryAssert.AreEqual('', TokenValue(Tokens, 2), 'empty string value');
    end;

    [Test]
    procedure RejectsUnterminatedStringEndingInEscapedQuote()
    var
        Tokens: JsonArray;
        Err: Text;
    begin
        // Filter text: Name eq 'abc''  — the trailing '' is an escaped apostrophe, so the
        // literal is never closed.
        LibraryAssert.IsFalse(Lexer.Tokenize(StrSubstNo('Name eq %1abc%1%1', Apo()), Tokens, Err), 'should fail');
    end;

    local procedure Apo(): Text
    begin
        exit('''');
    end;

    local procedure TokenKind(Tokens: JsonArray; Index: Integer): Text
    begin
        exit(TokenPart(Tokens, Index, 'kind'));
    end;

    local procedure TokenValue(Tokens: JsonArray; Index: Integer): Text
    begin
        exit(TokenPart(Tokens, Index, 'value'));
    end;

    local procedure TokenPart(Tokens: JsonArray; Index: Integer; Part: Text): Text
    var
        TokJ: JsonToken;
        Inner: JsonToken;
    begin
        Tokens.Get(Index, TokJ);
        TokJ.AsObject().Get(Part, Inner);
        exit(Inner.AsValue().AsText());
    end;
}
