codeunit 94336 "Bcmag Field Masker Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    // The mask renderer (pure text rules, the fall-back to the built-in PARTIAL shape, non-text field
    // handling) and the keyed strong ETag. The expected strings are spelled out literally: the masks are
    // a contract with API consumers, so a change in a rule must fail here, not slide by.

    var
        Masker: Codeunit "Bcmag Field Masker";
        Projector: Codeunit "Bcmag Projector";
        HashKey: Codeunit "Bcmag Hash Key";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";

    // ---- Keep* kinds -----------------------------------------------------------------------------

    [Test]
    procedure KeepLastHidesTheRestWithFixedFill()
    begin
        Helper.UpsertMaskProfile('T-KL2', "Bcmag Mask Kind"::KeepLast, 0, 2, 4, false);
        LibraryAssert.AreEqual('****45', Masker.MaskText('5812345', 'T-KL2'), 'fill is four mask chars when length is not preserved');
    end;

    [Test]
    procedure KeepLastPreservesLengthWhenAsked()
    begin
        Helper.UpsertMaskProfile('T-KL2P', "Bcmag Mask Kind"::KeepLast, 0, 2, 4, true);
        LibraryAssert.AreEqual('*****45', Masker.MaskText('5812345', 'T-KL2P'), 'five hidden chars stay five');
    end;

    [Test]
    procedure ShortValueIsFullyMaskedBelowMinHidden()
    begin
        // Review focus: 'last 2 of 5' would reveal 40% of the value; Min Hidden 4 must refuse both.
        Helper.UpsertMaskProfile('T-KL2', "Bcmag Mask Kind"::KeepLast, 0, 2, 4, false);
        LibraryAssert.AreEqual('****', Masker.MaskText('12345', 'T-KL2'), '3 hidden < 4 means full mask');
        LibraryAssert.AreEqual('****', Masker.MaskText('1234', 'T-KL2'), '2 hidden < 4 means full mask');
    end;

    [Test]
    procedure KeepFirstLastKeepsBothEnds()
    begin
        Helper.UpsertMaskProfile('T-KFL', "Bcmag Mask Kind"::KeepFirstLast, 1, 1, 4, false);
        LibraryAssert.AreEqual('A****H', Masker.MaskText('ABCDEFGH', 'T-KFL'), 'first and last kept');
    end;

    [Test]
    procedure KeepFirstKeepsOnlyTheHead()
    begin
        Helper.UpsertMaskProfile('T-KF', "Bcmag Mask Kind"::KeepFirst, 2, 0, 4, false);
        LibraryAssert.AreEqual('AB****', Masker.MaskText('ABCDEFGH', 'T-KF'), 'first two kept');
    end;

    [Test]
    procedure FullMaskPreservesLengthWhenAsked()
    begin
        Helper.UpsertMaskProfile('T-KL2P', "Bcmag Mask Kind"::KeepLast, 0, 2, 4, true);
        LibraryAssert.AreEqual('*****', Masker.MaskText('12345', 'T-KL2P'), 'full mask keeps the length');
    end;

    // ---- Email / Fixed / Null / Hash -------------------------------------------------------------

    [Test]
    procedure EmailKeepsFirstCharAndDomain()
    begin
        Helper.UpsertMaskProfile('T-EML', "Bcmag Mask Kind"::Email, 0, 0, 4, false);
        LibraryAssert.AreEqual('j****@example.com', Masker.MaskText('jonas@example.com', 'T-EML'), 'local part masked, domain kept');
    end;

    [Test]
    procedure EmailShortLocalPartIsFullyMaskedBelowMinHidden()
    var
        LocalMasker: Codeunit "Bcmag Field Masker";
    begin
        // Min Hidden applies to the local part: keeping the first character of 'a', 'jo' or 'jon' would
        // hide fewer than 4 characters, so the whole local part is masked and only '@domain' stays.
        // Without Preserve Length the fill is the fixed four characters.
        Helper.UpsertMaskProfile('T-EML', "Bcmag Mask Kind"::Email, 0, 0, 4, false);
        LibraryAssert.AreEqual('****@x.com', LocalMasker.MaskText('a@x.com', 'T-EML'), 'a one-character local part is never shown');
        LibraryAssert.AreEqual('****@x.com', LocalMasker.MaskText('jo@x.com', 'T-EML'), 'jo: 1 hidden < 4 means the whole local part');
        LibraryAssert.AreEqual('****@example.com', LocalMasker.MaskText('jon@example.com', 'T-EML'), 'jon: 2 hidden < 4 means the whole local part');
    end;

    [Test]
    procedure EmailShortLocalPartWithPreserveLengthIsFullyMasked()
    var
        LocalMasker: Codeunit "Bcmag Field Masker";
    begin
        // With Preserve Length the masked local part keeps its length, but no character of it is shown.
        Helper.UpsertMaskProfile('T-EMLP', "Bcmag Mask Kind"::Email, 0, 0, 4, true);
        LibraryAssert.AreEqual('*@x.com', LocalMasker.MaskText('a@x.com', 'T-EMLP'), 'a@x.com is no longer revealed');
        LibraryAssert.AreEqual('**@x.com', LocalMasker.MaskText('jo@x.com', 'T-EMLP'), 'jo@x.com no longer shows its first letter');
        LibraryAssert.AreEqual('j****@x.com', LocalMasker.MaskText('jonas@x.com', 'T-EMLP'), '4 hidden = Min Hidden keeps the first letter');
    end;

    [Test]
    procedure EmailWithoutLocalPartIsFullyMasked()
    begin
        Helper.UpsertMaskProfile('T-EML', "Bcmag Mask Kind"::Email, 0, 0, 4, false);
        LibraryAssert.AreEqual('****', Masker.MaskText('@x.com', 'T-EML'), 'nothing before @ means full mask');
        LibraryAssert.AreEqual('****', Masker.MaskText('nobody', 'T-EML'), 'no @ means full mask');
    end;

    [Test]
    procedure FixedReturnsTheFixedText()
    var
        Profile: Record "Bcmag Mask Profile";
    begin
        Helper.UpsertMaskProfile('T-FIX', "Bcmag Mask Kind"::Fixed, 0, 0, 4, false);
        LibraryAssert.AreEqual('[redacted]', Masker.MaskText('secret', 'T-FIX'), 'default fixed text');

        Profile.Get('T-FIX');
        Profile."Fixed Text" := 'HIDDEN';
        Profile.Modify();
        // The masker caches each profile per instance, so a fresh instance sees the edit.
        Clear(Masker);
        LibraryAssert.AreEqual('HIDDEN', Masker.MaskText('secret', 'T-FIX'), 'configured fixed text');
    end;

    [Test]
    procedure BlankFixedTextFallsBackToRedacted()
    var
        Profile: Record "Bcmag Mask Profile";
        LocalMasker: Codeunit "Bcmag Field Masker";
    begin
        // A real Fixed profile whose Fixed Text was cleared must not render '' — an agent would read a
        // filled field as empty.
        Helper.UpsertMaskProfile('T-FIXB', "Bcmag Mask Kind"::Fixed, 0, 0, 4, false);
        Profile.Get('T-FIXB');
        Profile."Fixed Text" := '';
        Profile.Modify();
        LibraryAssert.AreEqual('[redacted]', LocalMasker.MaskText('secret', 'T-FIXB'), 'a blank Fixed Text renders [redacted]');
    end;

    [Test]
    procedure MinHiddenBelowOneIsTreatedAsOne()
    var
        LocalMasker: Codeunit "Bcmag Field Masker";
    begin
        // UpsertMaskProfile assigns Min Hidden without Validate, so 0 lands in the row the way a code or
        // configuration-package write would. Unclamped, KeepLast 2 on '12' would render '****12'.
        Helper.UpsertMaskProfile('T-KL2Z', "Bcmag Mask Kind"::KeepLast, 0, 2, 0, false);
        LibraryAssert.AreEqual('****', LocalMasker.MaskText('12', 'T-KL2Z'), 'nothing hidden < 1 means full mask');
        LibraryAssert.AreEqual('****23', LocalMasker.MaskText('123', 'T-KL2Z'), 'one hidden character meets the clamped minimum');
        Helper.UpsertMaskProfile('T-EMLZ', "Bcmag Mask Kind"::Email, 0, 0, 0, false);
        LibraryAssert.AreEqual('****@x.com', LocalMasker.MaskText('a@x.com', 'T-EMLZ'), 'an email local part of one character is still masked');
    end;

    [Test]
    procedure HashIsStableDistinguishingAndPrefixed()
    var
        A1, A2, B: Text;
    begin
        Helper.UpsertMaskProfile('T-HASH', "Bcmag Mask Kind"::Hash, 0, 0, 4, false);
        A1 := Masker.MaskText('alpha', 'T-HASH');
        A2 := Masker.MaskText('alpha', 'T-HASH');
        B := Masker.MaskText('beta', 'T-HASH');

        LibraryAssert.AreEqual(A1, A2, 'equal inputs give equal hashes');
        LibraryAssert.AreNotEqual(A1, B, 'different inputs give different hashes');
        LibraryAssert.IsTrue(A1.StartsWith('h:'), 'h: prefix');
        LibraryAssert.AreEqual(18, StrLen(A1), 'h: plus 16 hex chars');
    end;

    [Test]
    procedure EmptyValueStaysEmpty()
    begin
        Helper.UpsertMaskProfile('T-KL2', "Bcmag Mask Kind"::KeepLast, 0, 2, 4, false);
        Helper.UpsertMaskProfile('T-FIX', "Bcmag Mask Kind"::Fixed, 0, 0, 4, false);
        LibraryAssert.AreEqual('', Masker.MaskText('', 'T-KL2'), 'keep kind');
        LibraryAssert.AreEqual('', Masker.MaskText('', 'T-FIX'), 'fixed kind');
    end;

    [Test]
    procedure UnknownAndBlankProfileUseBuiltInPartial()
    begin
        LibraryAssert.AreEqual('****45', Masker.MaskText('5812345', 'NO-SUCH-PROFILE'), 'unknown code');
        LibraryAssert.AreEqual('****45', Masker.MaskText('5812345', ''), 'blank code');
        LibraryAssert.AreEqual('****', Masker.MaskText('12345', ''), 'built-in min hidden 4');
        LibraryAssert.AreEqual('keepLast', Masker.KindName(''), 'blank code reports keepLast');
    end;

    [Test]
    procedure KindNamesAreInvariant()
    begin
        Helper.UpsertMaskProfile('T-EML', "Bcmag Mask Kind"::Email, 0, 0, 4, false);
        Helper.UpsertMaskProfile('T-FIX', "Bcmag Mask Kind"::Fixed, 0, 0, 4, false);
        Helper.UpsertMaskProfile('T-NUL', "Bcmag Mask Kind"::Null, 0, 0, 4, false);
        Helper.UpsertMaskProfile('T-HASH', "Bcmag Mask Kind"::Hash, 0, 0, 4, false);
        Helper.UpsertMaskProfile('T-KF', "Bcmag Mask Kind"::KeepFirst, 2, 0, 4, false);
        Helper.UpsertMaskProfile('T-KFL', "Bcmag Mask Kind"::KeepFirstLast, 1, 1, 4, false);
        LibraryAssert.AreEqual('email', Masker.KindName('T-EML'), 'email');
        LibraryAssert.AreEqual('fixed', Masker.KindName('T-FIX'), 'fixed');
        LibraryAssert.AreEqual('null', Masker.KindName('T-NUL'), 'null');
        LibraryAssert.AreEqual('hash', Masker.KindName('T-HASH'), 'hash');
        LibraryAssert.AreEqual('keepFirst', Masker.KindName('T-KF'), 'keepFirst');
        LibraryAssert.AreEqual('keepFirstLast', Masker.KindName('T-KFL'), 'keepFirstLast');
    end;

    // ---- FieldRef emission -----------------------------------------------------------------------

    [Test]
    procedure KeepKindOnDecimalFieldIsNull()
    var
        Customer: Record Customer;
        RecRef: RecordRef;
        Target: JsonObject;
        Tok: JsonToken;
    begin
        Helper.UpsertMaskProfile('T-KL2', "Bcmag Mask Kind"::KeepLast, 0, 2, 4, false);
        Customer.Init();
        Customer."Credit Limit (LCY)" := 12345;
        RecRef.GetTable(Customer);

        Masker.AddMaskedValue(Target, 'CreditLimit', RecRef.Field(Customer.FieldNo("Credit Limit (LCY)")), 'T-KL2');

        LibraryAssert.IsTrue(Target.Get('CreditLimit', Tok), 'property present');
        LibraryAssert.IsTrue(Tok.AsValue().IsNull(), 'a partial mask cannot render a number, so null');
        LibraryAssert.AreEqual('number', Masker.EmittedTypeName(FieldType::Decimal, 'T-KL2', 'number'), 'type unchanged for null');
    end;

    [Test]
    procedure HashKindOnDecimalFieldIsHashString()
    var
        Customer: Record Customer;
        RecRef: RecordRef;
        Target: JsonObject;
        Tok: JsonToken;
    begin
        Helper.UpsertMaskProfile('T-HASH', "Bcmag Mask Kind"::Hash, 0, 0, 4, false);
        Customer.Init();
        Customer."Credit Limit (LCY)" := 12345;
        RecRef.GetTable(Customer);

        Masker.AddMaskedValue(Target, 'CreditLimit', RecRef.Field(Customer.FieldNo("Credit Limit (LCY)")), 'T-HASH');

        LibraryAssert.IsTrue(Target.Get('CreditLimit', Tok), 'property present');
        LibraryAssert.IsTrue(Tok.AsValue().AsText().StartsWith('h:'), 'hash string');
        LibraryAssert.AreEqual('string', Masker.EmittedTypeName(FieldType::Decimal, 'T-HASH', 'number'), 'type becomes string');
        LibraryAssert.AreEqual('code', Masker.EmittedTypeName(FieldType::Code, 'T-HASH', 'code'), 'text-like types keep their name');
    end;

    [Test]
    procedure HashKindOnBooleanAndOptionFieldsIsNull()
    var
        Customer: Record Customer;
        LocalMasker: Codeunit "Bcmag Field Masker";
        RecRef: RecordRef;
        Target: JsonObject;
        Tok: JsonToken;
    begin
        // A deterministic token over two (or a handful of) values re-identifies every row once one row's
        // value is known, so Hash renders null on Boolean and Option/Enum fields, and describe reports
        // the field's own type with kind "null".
        Helper.UpsertMaskProfile('T-HASH', "Bcmag Mask Kind"::Hash, 0, 0, 4, false);
        Customer.Init();
        Customer."Prices Including VAT" := true;
        Customer.Blocked := Customer.Blocked::All;
        RecRef.GetTable(Customer);

        LocalMasker.AddMaskedValue(Target, 'PricesInclVat', RecRef.Field(Customer.FieldNo("Prices Including VAT")), 'T-HASH');
        LibraryAssert.IsTrue(Target.Get('PricesInclVat', Tok), 'property present');
        LibraryAssert.IsTrue(Tok.AsValue().IsNull(), 'Hash on a Boolean renders null');
        LocalMasker.AddMaskedValue(Target, 'Blocked', RecRef.Field(Customer.FieldNo(Blocked)), 'T-HASH');
        LibraryAssert.IsTrue(Target.Get('Blocked', Tok), 'property present');
        LibraryAssert.IsTrue(Tok.AsValue().IsNull(), 'Hash on an Option/Enum renders null');

        LibraryAssert.AreEqual('boolean', LocalMasker.EmittedTypeName(FieldType::Boolean, 'T-HASH', 'boolean'), 'a Boolean keeps its own type');
        LibraryAssert.AreEqual('null', LocalMasker.EffectiveKindName(FieldType::Boolean, 'T-HASH'), 'describe reports kind null on a Boolean');
        LibraryAssert.AreEqual('null', LocalMasker.EffectiveKindName(FieldType::Option, 'T-HASH'), 'describe reports kind null on an Option');
        LibraryAssert.AreEqual('hash', LocalMasker.EffectiveKindName(FieldType::Decimal, 'T-HASH'), 'other types keep kind hash');
    end;

    [Test]
    procedure TextFieldIsMasked()
    var
        Customer: Record Customer;
        RecRef: RecordRef;
        Target: JsonObject;
        Tok: JsonToken;
    begin
        Helper.UpsertMaskProfile('T-KL2', "Bcmag Mask Kind"::KeepLast, 0, 2, 4, false);
        Customer.Init();
        Customer.Name := '5812345';
        RecRef.GetTable(Customer);

        Masker.AddMaskedValue(Target, 'Name', RecRef.Field(Customer.FieldNo(Name)), 'T-KL2');

        LibraryAssert.IsTrue(Target.Get('Name', Tok), 'property present');
        LibraryAssert.AreEqual('****45', Tok.AsValue().AsText(), 'masked text');
    end;

    [Test]
    procedure NullKindOnTextFieldIsNull()
    var
        Customer: Record Customer;
        RecRef: RecordRef;
        Target: JsonObject;
        Tok: JsonToken;
    begin
        Helper.UpsertMaskProfile('T-NUL', "Bcmag Mask Kind"::Null, 0, 0, 4, false);
        Customer.Init();
        Customer.Name := 'Someone';
        RecRef.GetTable(Customer);

        Masker.AddMaskedValue(Target, 'Name', RecRef.Field(Customer.FieldNo(Name)), 'T-NUL');

        LibraryAssert.IsTrue(Target.Get('Name', Tok), 'property present');
        LibraryAssert.IsTrue(Tok.AsValue().IsNull(), 'null kind');
    end;

    // ---- keyed strong ETag -----------------------------------------------------------------------

    [Test]
    procedure StrongEtagIsKeyedAndStable()
    var
        Customer: Record Customer;
        FieldRec: Record Field;
        CryptographyMgt: Codeunit "Cryptography Management";
        Base64: Codeunit "Base64 Convert";
        RecRef: RecordRef;
        HashAlgorithm: Option MD5,SHA1,SHA256,SHA384,SHA512;
        Builder: TextBuilder;
        Modified: DateTime;
        Keyed1, Keyed2, Unkeyed: Text;
    begin
        // The old token was SHA-256(values) with no key, so a caller who knew a low-entropy hidden value
        // could confirm a guess offline. The keyed token must differ from that formula and stay stable.
        Customer.Init();
        Customer."No." := 'P-HMAC';
        Customer.Name := 'Keyed';
        Customer.Insert();
        RecRef.GetTable(Customer);

        Keyed1 := Projector.EtagOf(RecRef, true);
        Keyed2 := Projector.EtagOf(RecRef, true);
        LibraryAssert.AreEqual(Keyed1, Keyed2, 'stable across two calls');

        FieldRec.SetRange(TableNo, Database::Customer);
        FieldRec.SetRange(Class, FieldRec.Class::Normal);
        FieldRec.SetFilter(Type, '<>%1&<>%2&<>%3', FieldRec.Type::BLOB, FieldRec.Type::Media, FieldRec.Type::MediaSet);
        if FieldRec.FindSet() then
            repeat
                if RecRef.FieldExist(FieldRec."No.") then begin
                    Builder.Append(Format(FieldRec."No."));
                    Builder.Append('=');
                    Builder.Append(Format(RecRef.Field(FieldRec."No.").Value, 0, 9));
                    Builder.Append(';');
                end;
            until FieldRec.Next() = 0;
        Modified := RecRef.Field(2000000003).Value;
        Unkeyed := Base64.ToBase64(Format(Modified, 0, 9) + '|' + CryptographyMgt.GenerateHash(Builder.ToText(), HashAlgorithm::SHA256), false);

        LibraryAssert.AreNotEqual(Unkeyed, Keyed1, 'keyed token must not equal the plain SHA-256 token');
        LibraryAssert.AreEqual(Projector.EtagOf(RecRef, true), Keyed1, 'EtagOf(RecRef, true) is the one source of the token');
    end;

    [Test]
    procedure HmacIsLowercaseHexOf64Chars()
    var
        Digest: Text;
    begin
        Digest := HashKey.Hmac('abc');
        LibraryAssert.AreEqual(64, StrLen(Digest), 'SHA-256 hex is 64 chars');
        LibraryAssert.AreEqual(LowerCase(Digest), Digest, 'lowercase');
        LibraryAssert.AreEqual(Digest, HashKey.Hmac('abc'), 'deterministic for the tenant key');
        LibraryAssert.AreNotEqual(Digest, HashKey.Hmac('abd'), 'input-sensitive');
    end;
}
