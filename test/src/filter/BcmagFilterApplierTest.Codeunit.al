codeunit 94308 "Bcmag Filter Applier Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

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
        // The applier consults the field policy at resolution time; pin the AllFields baseline
        // so these unit tests exercise filter semantics, not policy (Bcmag Field Policy Test
        // covers the restricted paths).
        Helper.ConfigureOpenMode();
        if not Customer.IsEmpty() then
            Customer.DeleteAll();
        Customer.Init(); Customer."No." := 'A-1'; Customer.Name := 'Acme';     Customer.Insert();
        Customer.Init(); Customer."No." := 'B-1'; Customer.Name := 'Beta Ltd'; Customer.Insert();
        Customer.Init(); Customer."No." := 'C-1'; Customer.Name := 'Acme Two'; Customer.Insert();
        Customer.Init(); Customer."No." := 'D-1'; Customer.Name := 'O''Brien'; Customer."Privacy Blocked" := true; Customer.Insert();
    end;

    local procedure BuildAst(Filter: Text) Ast: JsonObject
    var
        Tokens: JsonArray;
        Err: Text;
    begin
        LibraryAssert.IsTrue(Lexer.Tokenize(Filter, Tokens, Err), Err);
        LibraryAssert.IsTrue(Parser.Parse(Tokens, Ast, Err), Err);
    end;

    [Test]
    procedure FiltersByEquality()
    var
        Customer: Record Customer;
        RecRef: RecordRef;
        Err: Text;
    begin
        SeedCustomers();
        RecRef.Open(Database::Customer);
        LibraryAssert.IsTrue(Applier.Apply(RecRef, BuildAst('Name eq ''Acme'''), Err), Err);
        LibraryAssert.AreEqual(1, RecRef.Count(), 'expected one Acme');
    end;

    [Test]
    procedure FiltersByStartswith()
    var
        RecRef: RecordRef;
        Err: Text;
    begin
        SeedCustomers();
        RecRef.Open(Database::Customer);
        LibraryAssert.IsTrue(Applier.Apply(RecRef, BuildAst('startswith(Name, ''Ac'')'), Err), Err);
        LibraryAssert.AreEqual(2, RecRef.Count(), 'expected two Ac*');
    end;

    [Test]
    procedure FiltersByIn()
    var
        RecRef: RecordRef;
        Err: Text;
    begin
        SeedCustomers();
        RecRef.Open(Database::Customer);
        LibraryAssert.IsTrue(Applier.Apply(RecRef, BuildAst('"No." in (''A-1'', ''C-1'')'), Err), Err);
        LibraryAssert.AreEqual(2, RecRef.Count(), 'expected two');
    end;

    [Test]
    procedure FiltersByEqualityWithEscapedApostrophe()
    var
        RecRef: RecordRef;
        Err: Text;
    begin
        // Filter text: Name eq 'O''Brien' — the round trip (unescape in the lexer, re-escape
        // in the applier) must match the literal value O'Brien.
        SeedCustomers();
        RecRef.Open(Database::Customer);
        LibraryAssert.IsTrue(Applier.Apply(RecRef, BuildAst('Name eq ''O''''Brien'''), Err), Err);
        LibraryAssert.AreEqual(1, RecRef.Count(), 'expected one O''Brien');
    end;

    [Test]
    procedure FiltersByStartswithWithEscapedApostrophe()
    var
        RecRef: RecordRef;
        Err: Text;
    begin
        // Filter text: startswith(Name, 'O''B')
        SeedCustomers();
        RecRef.Open(Database::Customer);
        LibraryAssert.IsTrue(Applier.Apply(RecRef, BuildAst('startswith(Name, ''O''''B'')'), Err), Err);
        LibraryAssert.AreEqual(1, RecRef.Count(), 'expected one O''B*');
    end;

    [Test]
    procedure FiltersByBooleanEqTrue()
    var
        RecRef: RecordRef;
        Err: Text;
    begin
        SeedCustomers();
        RecRef.Open(Database::Customer);
        LibraryAssert.IsTrue(Applier.Apply(RecRef, BuildAst('"Privacy Blocked" eq true'), Err), Err);
        LibraryAssert.AreEqual(1, RecRef.Count(), 'expected one privacy-blocked customer');
    end;

    [Test]
    procedure FiltersByBooleanNeTrue()
    var
        RecRef: RecordRef;
        Err: Text;
    begin
        SeedCustomers();
        RecRef.Open(Database::Customer);
        LibraryAssert.IsTrue(Applier.Apply(RecRef, BuildAst('"Privacy Blocked" ne true'), Err), Err);
        LibraryAssert.AreEqual(3, RecRef.Count(), 'expected the three non-blocked customers');
    end;

    [Test]
    procedure RejectsBoolLiteralOnNonBooleanField()
    var
        RecRef: RecordRef;
        Err: Text;
    begin
        SeedCustomers();
        RecRef.Open(Database::Customer);
        LibraryAssert.IsFalse(Applier.Apply(RecRef, BuildAst('Name eq true'), Err), 'should fail');
        LibraryAssert.IsTrue(Err <> '', 'expected an error message');
    end;

    [Test]
    procedure RejectsBoolLiteralWithOrderingOperator()
    var
        RecRef: RecordRef;
        Err: Text;
    begin
        SeedCustomers();
        RecRef.Open(Database::Customer);
        LibraryAssert.IsFalse(Applier.Apply(RecRef, BuildAst('"Privacy Blocked" gt true'), Err), 'should fail');
        LibraryAssert.IsTrue(Err <> '', 'expected an error message');
    end;

    [Test]
    procedure InListNumbersAreAppliedAsTypedValues()
    var
        Customer: Record Customer;
        RecRef: RecordRef;
        Err: Text;
    begin
        // Numeric in() members are parsed invariantly (1.5 is one and a half in every region) and
        // reach SetFilter as Decimal values, not as text the session locale would re-parse.
        SeedCustomers();
        Customer.Get('A-1'); Customer."Credit Limit (LCY)" := 1.5; Customer.Modify();
        Customer.Get('B-1'); Customer."Credit Limit (LCY)" := 2.25; Customer.Modify();
        Customer.Get('C-1'); Customer."Credit Limit (LCY)" := 15; Customer.Modify();
        RecRef.Open(Database::Customer);
        LibraryAssert.IsTrue(Applier.Apply(RecRef, BuildAst('"Credit Limit (LCY)" in (1.5, 2.25)'), Err), Err);
        LibraryAssert.AreEqual(2, RecRef.Count(), 'expected the 1.5 and 2.25 rows only');
    end;

    [Test]
    procedure InListDatesAreAppliedAsTypedValues()
    var
        Customer: Record Customer;
        RecRef: RecordRef;
        Err: Text;
    begin
        SeedCustomers();
        Customer.Get('A-1'); Customer."Last Date Modified" := DMY2Date(3, 1, 2026); Customer.Modify();
        Customer.Get('B-1'); Customer."Last Date Modified" := DMY2Date(1, 3, 2026); Customer.Modify();
        RecRef.Open(Database::Customer);
        LibraryAssert.IsTrue(Applier.Apply(RecRef, BuildAst('"Last Date Modified" in (2026-01-03)'), Err), Err);
        LibraryAssert.AreEqual(1, RecRef.Count(), 'the ISO date must not be read day/month-swapped');
        RecRef.FindFirst();
        LibraryAssert.AreEqual('A-1', Format(RecRef.Field(Customer.FieldNo("No.")).Value), 'expected the January row');
    end;

    [Test]
    procedure NumericLiteralsOnACodeFieldCompareAsText()
    var
        Customer: Record Customer;
        RecRef: RecordRef;
        Err: Text;
    begin
        // CRONUS-style numeric codes: "No." in (10000, 20000) must match the codes, not a Decimal
        // formatted in the session locale ("10,000"), which matches nothing.
        SeedCustomers();
        Customer.Init(); Customer."No." := '10000'; Customer.Insert();
        Customer.Init(); Customer."No." := '20000'; Customer.Insert();
        RecRef.Open(Database::Customer);
        LibraryAssert.IsTrue(Applier.Apply(RecRef, BuildAst('"No." in (10000, 20000)'), Err), Err);
        LibraryAssert.AreEqual(2, RecRef.Count(), 'both numeric codes must match');
        RecRef.Close();
        RecRef.Open(Database::Customer);
        LibraryAssert.IsTrue(Applier.Apply(RecRef, BuildAst('"No." eq 10000'), Err), Err);
        LibraryAssert.AreEqual(1, RecRef.Count(), 'eq on a numeric code must match it');
    end;
}
