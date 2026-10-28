codeunit 94303 "Bcmag Type Mapper Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        Mapper: Codeunit "Bcmag Type Mapper";
        LibraryAssert: Codeunit "Library Assert";

    local procedure GetThreshold(): BigInteger
    begin
        exit(9007199254740992L);
    end;

    // JsonValue has no IsString() (AL0132). A JSON string serialises with surrounding quotes;
    // numbers/booleans/null do not — so a leading '"' distinguishes a string.
    local procedure IsJsonString(JVal: JsonValue): Boolean
    var
        Serialized: Text;
    begin
        if JVal.IsNull() or JVal.IsUndefined() then
            exit(false);
        JVal.WriteTo(Serialized);
        exit(Serialized.StartsWith('"'));
    end;

    [Test]
    procedure EmptyCodeSerializesAsNull()
    var
        Customer: Record Customer;
        RecRef: RecordRef;
        FieldRef: FieldRef;
        Tok: JsonToken;
    begin
        Customer.Init();
        Customer."No." := 'INT-1';
        RecRef.GetTable(Customer);
        FieldRef := RecRef.Field(Customer.FieldNo("No. Series"));
        Tok := Mapper.FieldRefToJson(FieldRef, GetThreshold());
        LibraryAssert.IsTrue(Tok.IsValue(), 'expected a scalar JSON value');
        LibraryAssert.IsTrue(Tok.AsValue().IsNull(), 'expected null for empty Code');
    end;

    [Test]
    procedure CodeSerializesAsTrimmedString()
    var
        Customer: Record Customer;
        RecRef: RecordRef;
        Tok: JsonToken;
    begin
        Customer.Init();
        Customer."No." := 'C-001';
        RecRef.GetTable(Customer);
        Tok := Mapper.FieldRefToJson(RecRef.Field(Customer.FieldNo("No.")), GetThreshold());
        LibraryAssert.IsTrue(IsJsonString(Tok.AsValue()), 'Code should be a string');
        LibraryAssert.AreEqual('C-001', Tok.AsValue().AsText(), 'Code should round-trip');
    end;

    [Test]
    procedure DateSerializesAsIsoDate()
    var
        Customer: Record Customer;
        RecRef: RecordRef;
        Tok: JsonToken;
    begin
        Customer.Init();
        Customer."Last Date Modified" := DMY2Date(8, 5, 2026);
        RecRef.GetTable(Customer);
        Tok := Mapper.FieldRefToJson(RecRef.Field(Customer.FieldNo("Last Date Modified")), GetThreshold());
        LibraryAssert.AreEqual('2026-05-08', Tok.AsValue().AsText(), 'Date format');
    end;

    [Test]
    procedure DecimalAboveThresholdSerializesAsExactString()
    var
        Customer: Record Customer;
        RecRef: RecordRef;
        FieldRef: FieldRef;
        Tok: JsonToken;
        Big: Decimal;
    begin
        // BC's Decimal range tops out at 999,999,999,999,999.99 — BELOW the 2^53 default threshold —
        // so the string path is exercised with an explicit lower threshold (1e14) and a value above
        // it. (The first CI run failed here: 1e16 is outside the platform's permitted Decimal range.)
        Big := 123456789012345.67;
        Customer.Init();
        Customer."No." := 'DEC-1';
        Customer."Credit Limit (LCY)" := Big;
        RecRef.GetTable(Customer);
        FieldRef := RecRef.Field(Customer.FieldNo("Credit Limit (LCY)"));
        Tok := Mapper.FieldRefToJson(FieldRef, 100000000000000L);
        LibraryAssert.IsTrue(IsJsonString(Tok.AsValue()), 'above-threshold decimal must be a string');
        LibraryAssert.AreEqual(Format(Big, 0, 9), Tok.AsValue().AsText(), 'exact invariant string expected');
    end;

    [Test]
    procedure DecimalBelowThresholdSerializesAsNumber()
    var
        Customer: Record Customer;
        RecRef: RecordRef;
        FieldRef: FieldRef;
        Tok: JsonToken;
    begin
        // A small decimal stays a JSON number (round-trips losslessly within 2^53).
        Customer.Init();
        Customer."No." := 'DEC-2';
        Customer."Credit Limit (LCY)" := 1234.56;
        RecRef.GetTable(Customer);
        FieldRef := RecRef.Field(Customer.FieldNo("Credit Limit (LCY)"));
        Tok := Mapper.FieldRefToJson(FieldRef, GetThreshold());
        LibraryAssert.IsFalse(IsJsonString(Tok.AsValue()), 'below-threshold decimal must be a JSON number');
        LibraryAssert.AreEqual(1234.56, Tok.AsValue().AsDecimal(), 'decimal value should round-trip');
    end;

    [Test]
    procedure OptionSerializesAsOrdNameObject()
    var
        Customer: Record Customer;
        RecRef: RecordRef;
        FieldRef: FieldRef;
        Tok, SubTok: JsonToken;
        Obj: JsonObject;
    begin
        // FieldRefToJson now returns a JsonToken; an Option yields an OBJECT {ord, name}.
        Customer.Init();
        Customer."No." := 'OPT-1';
        Customer."Application Method" := Customer."Application Method"::"Apply to Oldest";
        RecRef.GetTable(Customer);
        FieldRef := RecRef.Field(Customer.FieldNo("Application Method"));
        Tok := Mapper.FieldRefToJson(FieldRef, GetThreshold());
        LibraryAssert.IsTrue(Tok.IsObject(), 'Option should serialize as an object');
        Obj := Tok.AsObject();
        LibraryAssert.IsTrue(Obj.Get('ord', SubTok), 'ord missing');
        LibraryAssert.AreEqual(1, SubTok.AsValue().AsInteger(), 'ord should be 1 (Apply to Oldest)');
        LibraryAssert.IsTrue(Obj.Get('name', SubTok), 'name missing');
        LibraryAssert.AreEqual('Apply to Oldest', SubTok.AsValue().AsText(), 'name mismatch');
    end;
}
