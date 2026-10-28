codeunit 94315 "Bcmag Filter Injection Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    // Caller-supplied filter values carrying AL/OData metacharacters must never widen a comparison
    // or an in-list (spec §16 R16): those reach BC as %n SetFilter parameters, which the platform
    // treats as exact literals — including * and ?. Text functions (startswith/endswith/contains)
    // are different: the platform has no escape for * and ? inside a quoted wildcard literal, so a
    // caller's * or ? in a function value IS a wildcard. That is documented protocol behaviour, and
    // the tests below pin both halves. Everything runs through the real lexer -> parser -> applier.

    var
        Lexer: Codeunit "Bcmag Filter Lexer";
        Parser: Codeunit "Bcmag Filter Parser";
        Applier: Codeunit "Bcmag Filter Applier";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";

    local procedure SeedCustomers()
    var
        Customer: Record Customer;
    begin
        // Pin the AllFields field-policy baseline — these tests probe literal-vs-wildcard
        // semantics, not the field policy (covered by Bcmag Field Policy Test).
        Helper.ConfigureOpenMode();
        if not Customer.IsEmpty() then Customer.DeleteAll();
        // Names chosen so that wildcard expansion of the metacharacters would over-match.
        Customer.Init(); Customer."No." := 'A';   Customer.Name := 'A|B Holdings'; Customer.Insert();
        Customer.Init(); Customer."No." := '*';   Customer.Name := 'Star Co';      Customer.Insert();
        Customer.Init(); Customer."No." := 'AXB'; Customer.Name := 'AxB Mixed';     Customer.Insert();
        Customer.Init(); Customer."No." := 'BCO'; Customer.Name := 'B Only';        Customer.Insert();
        Customer.Init(); Customer."No." := 'OB1'; Customer.Name := 'O''Brien*';     Customer.Insert();
        Customer.Init(); Customer."No." := 'OB2'; Customer.Name := 'O''Brien Sons'; Customer.Insert();
        Customer.Init(); Customer."No." := 'DOTS'; Customer.Name := 'A..B Range';    Customer.Insert();
    end;

    local procedure ApplyFilter(var RecRef: RecordRef; Filter: Text)
    var
        Tokens: JsonArray;
        Ast: JsonObject;
        Err: Text;
    begin
        LibraryAssert.IsTrue(Lexer.Tokenize(Filter, Tokens, Err), Err);
        LibraryAssert.IsTrue(Parser.Parse(Tokens, Ast, Err), Err);
        LibraryAssert.IsTrue(Applier.Apply(RecRef, Ast, Err), Err);
    end;

    [Test]
    procedure ContainsTreatsPipeLiterally()
    var
        RecRef: RecordRef;
    begin
        // 'A|B' must match the single row whose Name literally contains "A|B", NOT every row
        // containing "A" or "B" (which an alternation/wildcard expansion would do).
        SeedCustomers();
        RecRef.Open(Database::Customer);
        ApplyFilter(RecRef, 'contains(Name, ''A|B'')');
        LibraryAssert.AreEqual(1, RecRef.Count(), 'pipe must be literal, not an OR alternation');
        RecRef.Close();
    end;

    [Test]
    procedure InListTreatsStarLiterally()
    var
        RecRef: RecordRef;
    begin
        // in ('A','*') must match exactly No.='A' and No.='*' (2 rows), NOT every row
        // (which a '*' wildcard would match).
        SeedCustomers();
        RecRef.Open(Database::Customer);
        ApplyFilter(RecRef, '"No." in (''A'', ''*'')');
        LibraryAssert.AreEqual(2, RecRef.Count(), 'star must be a literal member, not a wildcard');
        RecRef.Close();
    end;

    [Test]
    procedure EqualityTreatsStarLiterally()
    var
        RecRef: RecordRef;
    begin
        // No. eq '*' must match only the row whose No. is literally '*'.
        SeedCustomers();
        RecRef.Open(Database::Customer);
        ApplyFilter(RecRef, '"No." eq ''*''');
        LibraryAssert.AreEqual(1, RecRef.Count(), 'eq with star must match the literal star row only');
        RecRef.Close();
    end;

    [Test]
    procedure EqualityWithEscapedQuoteTreatsStarLiterally()
    var
        RecRef: RecordRef;
    begin
        // Name eq 'O''Brien*' — the escaped quote must not let the trailing * escape the
        // literal: only the row named exactly "O'Brien*" may match, NOT "O'Brien Sons"
        // (which a wildcard expansion of O'Brien* would also match).
        SeedCustomers();
        RecRef.Open(Database::Customer);
        ApplyFilter(RecRef, 'Name eq ''O''''Brien*''');
        LibraryAssert.AreEqual(1, RecRef.Count(), 'star after an escaped quote must stay literal');
        RecRef.Close();
    end;

    [Test]
    procedure ContainsStarInsideValueIsAWildcard()
    var
        RecRef: RecordRef;
    begin
        // contains(Name, 'O''Brien*') — inside a text-function value the platform keeps * as a
        // wildcard (there is no escape), so BOTH O'Brien rows match. The first CI run proved the
        // opposite expectation wrong; the skill documents this as protocol behaviour.
        SeedCustomers();
        RecRef.Open(Database::Customer);
        ApplyFilter(RecRef, 'contains(Name, ''O''''Brien*'')');
        LibraryAssert.AreEqual(2, RecRef.Count(), 'a star inside a contains() value is a wildcard');
        RecRef.Close();
    end;

    [Test]
    procedure StartswithQuestionMarkIsASingleCharWildcard()
    var
        RecRef: RecordRef;
    begin
        // startswith(Name, 'A?B') — ? matches exactly one character: "A|B Holdings" and "AxB Mixed",
        // but not "A..B Range" (two characters between A and B).
        SeedCustomers();
        RecRef.Open(Database::Customer);
        ApplyFilter(RecRef, 'startswith(Name, ''A?B'')');
        LibraryAssert.AreEqual(2, RecRef.Count(), '? inside a startswith() value is a one-character wildcard');
        RecRef.Close();
    end;

    [Test]
    procedure InListTreatsRangeDotsLiterally()
    var
        RecRef: RecordRef;
    begin
        // "No." in ('A', 'A..Z') — a %n parameter is exact, so 'A..Z' is a literal member (matching
        // nothing), NOT the lexicographic range A..Z (which would match every seeded row).
        SeedCustomers();
        RecRef.Open(Database::Customer);
        ApplyFilter(RecRef, '"No." in (''A'', ''A..Z'')');
        LibraryAssert.AreEqual(1, RecRef.Count(), 'a .. inside an in() member must not become a range');
        RecRef.Close();
    end;

    [Test]
    procedure EqualityTreatsRangeDotsLiterally()
    var
        RecRef: RecordRef;
    begin
        SeedCustomers();
        RecRef.Open(Database::Customer);
        ApplyFilter(RecRef, 'Name eq ''A..B Range''');
        LibraryAssert.AreEqual(1, RecRef.Count(), 'a .. inside an eq value must stay literal');
        RecRef.Close();
    end;
}
