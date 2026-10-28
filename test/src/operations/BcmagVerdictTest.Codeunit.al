codeunit 94334 "Bcmag Verdict Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    // The per-principal read verdict of "Bcmag Field Policy" (plan: "Verdict precedence"):
    //   AllFields → Clear; PK → Clear; baseline = field row, else Hidden (Explicit), else the
    //   classification rule; a field-scope user exception, else a classification-scope one, replaces
    //   the verdict; the Unmask tier lifts Masked to Clear only when no exception matched the field
    //   (an exception that decided the field is final); a request carrying "unmask": false gets
    //   MoreRestrictive(baseline, principal); a final verdict more permissive than the baseline is
    //   noted as a lift for the Operation Log. Writability follows the baseline only.
    //
    // Every verdict is read through a FRESH policy instance (Verdict / NewPolicy below), and every
    // test starts from Initialize: ByClassification, Unmask tier off (the suite runs as SUPER), no
    // exceptions for the caller and a neutral request (no "unmask" member, no lifts noted). Tests that
    // change a rule, a row or the request put them back before they end.

    var
        PolicyDefaults: Codeunit "Bcmag Policy Defaults";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";
        Scope: Option Classification,Field;

    // ---- baseline --------------------------------------------------------------------------------

    [Test]
    procedure FieldRowMaskedReadsMasked()
    var
        Policy: Codeunit "Bcmag Field Policy";
        ProfileCode: Code[20];
        NameNo: Integer;
    begin
        Initialize();
        NameNo := CustomerFieldNo('Name');
        Helper.SetFieldAccess(Database::Customer, NameNo, "Bcmag Read Access"::Masked, 'EMAIL', false);

        AssertAccess("Bcmag Read Access"::Masked, Policy.ReadVerdict(Database::Customer, NameNo, ProfileCode), 'a Masked row reads Masked');
        LibraryAssert.AreEqual('EMAIL', Format(ProfileCode), 'the row''s mask profile is returned');
        LibraryAssert.IsTrue(Policy.IsReadable(Database::Customer, NameNo), 'a Masked field is readable (emitted masked)');
        LibraryAssert.IsFalse(Policy.IsClear(Database::Customer, NameNo), 'a Masked field is not Clear');
        LibraryAssert.IsTrue(Policy.IsMasked(Database::Customer, NameNo), 'IsMasked');
        LibraryAssert.AreEqual('', Lifts(), 'a baseline verdict is no lift');

        Helper.UnexposeField(Database::Customer, NameNo);
    end;

    [Test]
    procedure ClassificationRuleMaskedWithoutRowReadsMasked()
    var
        FieldRec: Record Field;
        ProfileCode: Code[20];
        DataClass: Enum "Bcmag Data Class";
        NameNo: Integer;
    begin
        Initialize();
        NameNo := CustomerFieldNo('Name');
        Helper.UnexposeField(Database::Customer, NameNo);
        FieldRec.Get(Database::Customer, NameNo);
        DataClass := PolicyDefaults.DataClassOf(FieldRec);
        Helper.SetClassificationRule(DataClass, "Bcmag Read Access"::Masked, 'HASH');

        AssertAccess("Bcmag Read Access"::Masked, Verdict(NameNo, ProfileCode), 'the classification rule decides without a row');
        LibraryAssert.AreEqual('HASH', Format(ProfileCode), 'the rule''s mask profile is returned');

        RestoreBuiltInRule(DataClass);
    end;

    [Test]
    procedure ExplicitModeWithoutRowIsHidden()
    var
        ProfileCode: Code[20];
        NameNo: Integer;
    begin
        Initialize();
        NameNo := CustomerFieldNo('Name');
        Helper.UnexposeField(Database::Customer, NameNo);
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::Explicit);

        AssertAccess("Bcmag Read Access"::Hidden, Verdict(NameNo, ProfileCode), 'Explicit without a row is Hidden');
        LibraryAssert.AreEqual('', Format(ProfileCode), 'no profile for Hidden');

        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::ByClassification);
    end;

    [Test]
    procedure AllFieldsModeIgnoresHiddenRow()
    var
        Policy: Codeunit "Bcmag Field Policy";
        ProfileCode: Code[20];
        NameNo: Integer;
    begin
        Initialize();
        NameNo := CustomerFieldNo('Name');
        Helper.SetFieldAccess(Database::Customer, NameNo, "Bcmag Read Access"::Hidden, '', false);
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::AllFields);

        AssertAccess("Bcmag Read Access"::Clear, Policy.ReadVerdict(Database::Customer, NameNo, ProfileCode), 'AllFields ignores override rows');
        LibraryAssert.IsTrue(Policy.IsWritable(Database::Customer, NameNo), 'AllFields keeps every field writable');

        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::ByClassification);
        Helper.UnexposeField(Database::Customer, NameNo);
    end;

    [Test]
    procedure PrimaryKeyFieldIgnoresHiddenRow()
    var
        Policy: Codeunit "Bcmag Field Policy";
        ProfileCode: Code[20];
        PkNo: Integer;
    begin
        Initialize();
        PkNo := CustomerFieldNo('No.');
        Helper.SetFieldAccess(Database::Customer, PkNo, "Bcmag Read Access"::Hidden, '', false);

        AssertAccess("Bcmag Read Access"::Clear, Policy.ReadVerdict(Database::Customer, PkNo, ProfileCode), 'a PK field is always Clear');
        LibraryAssert.IsTrue(Policy.IsWritable(Database::Customer, PkNo), 'a PK field is always writable');

        Helper.UnexposeField(Database::Customer, PkNo);
    end;

    // ---- user exceptions -------------------------------------------------------------------------

    [Test]
    procedure FieldExceptionLiftsMaskedRowAndNotesLift()
    var
        ProfileCode: Code[20];
        NameNo: Integer;
    begin
        Initialize();
        NameNo := CustomerFieldNo('Name');
        Helper.SetFieldAccess(Database::Customer, NameNo, "Bcmag Read Access"::Masked, 'PARTIAL', false);
        Helper.AddUserException(Scope::Field, "Bcmag Data Class"::CustomerContent, Database::Customer, NameNo, "Bcmag Read Access"::Clear, '', 0DT);

        AssertAccess("Bcmag Read Access"::Clear, Verdict(NameNo, ProfileCode), 'a Clear exception replaces the Masked row');
        LibraryAssert.AreEqual('', Format(ProfileCode), 'no profile for Clear');
        LibraryAssert.IsTrue(StrPos(Lifts(), PairOf(NameNo)) > 0, 'the lift above the baseline is noted');

        Helper.ClearUserExceptions();
        Helper.UnexposeField(Database::Customer, NameNo);
    end;

    [Test]
    procedure ExpiredExceptionIsIgnored()
    var
        Policy: Codeunit "Bcmag Field Policy";
        ProfileCode: Code[20];
        NameNo: Integer;
    begin
        Initialize();
        NameNo := CustomerFieldNo('Name');
        Helper.SetFieldAccess(Database::Customer, NameNo, "Bcmag Read Access"::Masked, 'PARTIAL', false);
        Helper.AddUserException(Scope::Field, "Bcmag Data Class"::CustomerContent, Database::Customer, NameNo, "Bcmag Read Access"::Clear, '', CurrentDateTime() - 3600000);

        AssertAccess("Bcmag Read Access"::Masked, Policy.ReadVerdict(Database::Customer, NameNo, ProfileCode), 'an expired exception has no effect');
        LibraryAssert.AreEqual('PARTIAL', Format(ProfileCode), 'the row''s profile still applies');
        LibraryAssert.AreEqual(0, Policy.ActiveExceptionCount(), 'an expired exception is not active');
        LibraryAssert.AreEqual('', Lifts(), 'nothing is lifted');

        Helper.ClearUserExceptions();
        Helper.UnexposeField(Database::Customer, NameNo);
    end;

    [Test]
    procedure MalformedExceptionsAreIgnored()
    var
        ExcRow: Record "Bcmag Access Exception";
        Policy: Codeunit "Bcmag Field Policy";
        ProfileCode: Code[20];
        NameNo: Integer;
    begin
        // Defensive reading: an inverted validity window (Until before From) is never active, a
        // field-scope row without a table or field number is ignored, a not-yet-valid row waits — and
        // none of them raises an error on the read path.
        Initialize();
        NameNo := CustomerFieldNo('Name');
        Helper.SetFieldAccess(Database::Customer, NameNo, "Bcmag Read Access"::Masked, 'PARTIAL', false);

        InsertException(Scope::Field, Database::Customer, NameNo, CurrentDateTime() - 3600000, CurrentDateTime() - 7200000);
        InsertException(Scope::Field, Database::Customer, 0, 0DT, 0DT);
        InsertException(Scope::Field, 0, NameNo, 0DT, 0DT);
        InsertException(Scope::Field, Database::Customer, NameNo, CurrentDateTime() + 3600000, 0DT);
        ExcRow.SetRange("User Security ID", UserSecurityId());
        LibraryAssert.AreEqual(4, ExcRow.Count(), 'four malformed or pending rows exist');

        AssertAccess("Bcmag Read Access"::Masked, Policy.ReadVerdict(Database::Customer, NameNo, ProfileCode), 'malformed and pending exceptions have no effect');
        LibraryAssert.AreEqual(0, Policy.ActiveExceptionCount(), 'none of them is active');

        Helper.ClearUserExceptions();
        Helper.UnexposeField(Database::Customer, NameNo);
    end;

    [Test]
    procedure ActiveExceptionCountCountsOnlyActiveRows()
    var
        Policy: Codeunit "Bcmag Field Policy";
        NameNo: Integer;
    begin
        Initialize();
        NameNo := CustomerFieldNo('Name');
        Helper.AddUserException(Scope::Field, "Bcmag Data Class"::CustomerContent, Database::Customer, NameNo, "Bcmag Read Access"::Clear, '', 0DT);
        Helper.AddUserException(Scope::Classification, "Bcmag Data Class"::EndUserIdentifiableInformation, 0, 0, "Bcmag Read Access"::Clear, '', CurrentDateTime() + 3600000);
        Helper.AddUserException(Scope::Classification, "Bcmag Data Class"::AccountData, 0, 0, "Bcmag Read Access"::Clear, '', CurrentDateTime() - 3600000);

        LibraryAssert.AreEqual(2, Policy.ActiveExceptionCount(), 'two active exceptions, one expired');

        Helper.ClearUserExceptions();
    end;

    [Test]
    procedure ClassificationExceptionAppliesAndFieldExceptionWins()
    var
        FieldRec: Record Field;
        ProfileCode: Code[20];
        NameNo: Integer;
    begin
        Initialize();
        NameNo := CustomerFieldNo('Name');
        FieldRec.Get(Database::Customer, NameNo);
        Helper.SetFieldAccess(Database::Customer, NameNo, "Bcmag Read Access"::Masked, 'PARTIAL', false);

        // A classification-scope exception covers every field of the class, the row's field included.
        Helper.AddUserException(Scope::Classification, PolicyDefaults.DataClassOf(FieldRec), 0, 0, "Bcmag Read Access"::Clear, '', 0DT);
        AssertAccess("Bcmag Read Access"::Clear, Verdict(NameNo, ProfileCode), 'the classification exception replaces the row verdict');

        // A field-scope exception for the same field wins over the classification-scope one.
        Helper.AddUserException(Scope::Field, PolicyDefaults.DataClassOf(FieldRec), Database::Customer, NameNo, "Bcmag Read Access"::Masked, 'HASH', 0DT);
        AssertAccess("Bcmag Read Access"::Masked, Verdict(NameNo, ProfileCode), 'the field exception wins');
        LibraryAssert.AreEqual('HASH', Format(ProfileCode), 'the exception''s profile replaces the row''s');

        Helper.ClearUserExceptions();
        Helper.UnexposeField(Database::Customer, NameNo);
    end;

    // ---- "unmask": false (Review Focus 4) --------------------------------------------------------

    [Test]
    procedure HidingExceptionStillHidesWithUnmaskFalse()
    var
        Policy: Codeunit "Bcmag Field Policy";
        ProfileCode: Code[20];
        NameNo: Integer;
    begin
        Initialize();
        NameNo := CustomerFieldNo('Name');
        Helper.SetFieldAccess(Database::Customer, NameNo, "Bcmag Read Access"::Clear, '', false);
        Helper.AddUserException(Scope::Field, "Bcmag Data Class"::CustomerContent, Database::Customer, NameNo, "Bcmag Read Access"::Hidden, '', 0DT);

        AssertAccess("Bcmag Read Access"::Hidden, Verdict(NameNo, ProfileCode), 'a Hidden exception hides a Clear row');
        LibraryAssert.IsFalse(Policy.IsReadable(Database::Customer, NameNo), 'a hidden field is not readable');

        // The opt-out must never make a field MORE visible than the baseline: the exception still hides.
        SetUnmaskRequest(false);
        AssertAccess("Bcmag Read Access"::Hidden, Verdict(NameNo, ProfileCode), '"unmask": false keeps the hiding exception');
        LibraryAssert.AreEqual('', Lifts(), 'a tightening is no lift');

        NeutralRequest();
        Helper.ClearUserExceptions();
        Helper.UnexposeField(Database::Customer, NameNo);
    end;

    [Test]
    procedure UnmaskFalseKeepsMaskedAndNotesNoLift()
    var
        ProfileCode: Code[20];
        NameNo: Integer;
    begin
        Initialize();
        NameNo := CustomerFieldNo('Name');
        Helper.SetFieldAccess(Database::Customer, NameNo, "Bcmag Read Access"::Masked, 'PARTIAL', false);
        Helper.AddUserException(Scope::Field, "Bcmag Data Class"::CustomerContent, Database::Customer, NameNo, "Bcmag Read Access"::Clear, '', 0DT);
        SetUnmaskRequest(false);

        AssertAccess("Bcmag Read Access"::Masked, Verdict(NameNo, ProfileCode), '"unmask": false declines the Clear exception');
        LibraryAssert.AreEqual('PARTIAL', Format(ProfileCode), 'the baseline profile applies');
        LibraryAssert.AreEqual('', Lifts(), 'no lift is noted when the caller opts out');

        NeutralRequest();
        Helper.ClearUserExceptions();
        Helper.UnexposeField(Database::Customer, NameNo);
    end;

    [Test]
    procedure UnmaskFalseKeepsATighteningProfileException()
    var
        Policy: Codeunit "Bcmag Field Policy";
        ProfileCode: Code[20];
        NameNo: Integer;
    begin
        // Baseline Masked/PARTIAL, the caller's exception Masked/REDACT: same verdict, stricter profile.
        // The opt-out must not fall back to the baseline's PARTIAL — that would widen the view.
        Initialize();
        NameNo := CustomerFieldNo('Name');
        SeedProfileKinds();
        Helper.SetFieldAccess(Database::Customer, NameNo, "Bcmag Read Access"::Masked, 'PARTIAL', false);
        Helper.AddUserException(Scope::Field, "Bcmag Data Class"::CustomerContent, Database::Customer, NameNo, "Bcmag Read Access"::Masked, 'REDACT', 0DT);
        SetUnmaskRequest(false);

        AssertAccess("Bcmag Read Access"::Masked, Policy.ReadVerdict(Database::Customer, NameNo, ProfileCode), 'the field stays Masked');
        LibraryAssert.AreEqual('REDACT', Format(ProfileCode), '"unmask": false keeps the exception''s stricter profile');
        LibraryAssert.AreEqual('', Lifts(), 'a re-mask is no lift');

        NeutralRequest();
        Helper.ClearUserExceptions();
        Helper.UnexposeField(Database::Customer, NameNo);
    end;

    [Test]
    procedure UnmaskFalseDeclinesALooserProfileException()
    var
        Policy: Codeunit "Bcmag Field Policy";
        ProfileCode: Code[20];
        NameNo: Integer;
    begin
        // Baseline Masked/HASH (Hash, rank 3), the caller's exception Masked/PARTIAL (KeepLast, rank 1):
        // without the opt-out the exception applies; with it the stricter baseline profile is kept.
        Initialize();
        NameNo := CustomerFieldNo('Name');
        SeedProfileKinds();
        Helper.SetFieldAccess(Database::Customer, NameNo, "Bcmag Read Access"::Masked, 'HASH', false);
        Helper.AddUserException(Scope::Field, "Bcmag Data Class"::CustomerContent, Database::Customer, NameNo, "Bcmag Read Access"::Masked, 'PARTIAL', 0DT);

        AssertAccess("Bcmag Read Access"::Masked, Verdict(NameNo, ProfileCode), 'the field is Masked');
        LibraryAssert.AreEqual('PARTIAL', Format(ProfileCode), 'by default the exception''s profile applies');

        SetUnmaskRequest(false);
        AssertAccess("Bcmag Read Access"::Masked, Policy.ReadVerdict(Database::Customer, NameNo, ProfileCode), 'the field stays Masked');
        LibraryAssert.AreEqual('HASH', Format(ProfileCode), '"unmask": false keeps the stricter baseline profile');
        LibraryAssert.AreEqual('', Lifts(), 'no lift is noted');

        NeutralRequest();
        Helper.ClearUserExceptions();
        Helper.UnexposeField(Database::Customer, NameNo);
    end;

    [Test]
    procedure UnmaskFlagReadsOnlyAnExplicitFalse()
    var
        Ctx: Codeunit "Bcmag Op Runner Context";
        Data: JsonObject;
    begin
        NeutralRequest();
        LibraryAssert.IsTrue(Ctx.UnmaskRequested(), 'absent → unmask');

        SetUnmaskRequest(false);
        LibraryAssert.IsFalse(Ctx.UnmaskRequested(), 'false → opt out');

        SetUnmaskRequest(true);
        LibraryAssert.IsTrue(Ctx.UnmaskRequested(), 'true → unmask');

        Data.Add('unmask', 'perhaps');
        Ctx.SetRequest('query', Data);
        LibraryAssert.IsTrue(Ctx.UnmaskRequested(), 'an unreadable value → unmask (the default)');

        NeutralRequest();
    end;

    // ---- writability -----------------------------------------------------------------------------

    [Test]
    procedure WritabilityFollowsTheBaselineOnly()
    var
        FieldRec: Record Field;
        Policy: Codeunit "Bcmag Field Policy";
        DataClass: Enum "Bcmag Data Class";
        NameNo: Integer;
    begin
        Initialize();
        NameNo := CustomerFieldNo('Name');
        Helper.UnexposeField(Database::Customer, NameNo);
        FieldRec.Get(Database::Customer, NameNo);
        DataClass := PolicyDefaults.DataClassOf(FieldRec);

        // Masked classification, no row: not writable — and a Clear exception does not change that.
        Helper.SetClassificationRule(DataClass, "Bcmag Read Access"::Masked, 'PARTIAL');
        Helper.AddUserException(Scope::Field, DataClass, Database::Customer, NameNo, "Bcmag Read Access"::Clear, '', 0DT);
        LibraryAssert.IsFalse(Policy.IsWritable(Database::Customer, NameNo), 'a Masked classification is not writable');
        LibraryAssert.IsTrue(Policy.IsClear(Database::Customer, NameNo), 'the exception governs reading');
        Helper.ClearUserExceptions();

        // A Masked field row with Allow Write is writable without being readable in clear.
        Clear(Policy);
        Helper.SetFieldAccess(Database::Customer, NameNo, "Bcmag Read Access"::Masked, '', true);
        LibraryAssert.IsTrue(Policy.IsWritable(Database::Customer, NameNo), 'Allow Write on a Masked row');
        LibraryAssert.IsTrue(Policy.IsMasked(Database::Customer, NameNo), 'the row still reads Masked');

        Helper.UnexposeField(Database::Customer, NameNo);
        RestoreBuiltInRule(DataClass);
    end;

    // ---- Unmask tier -----------------------------------------------------------------------------

    [Test]
    procedure UnmaskTierLiftsMaskedForTheHolder()
    var
        Policy: Codeunit "Bcmag Field Policy";
        ProfileCode: Code[20];
        NameNo: Integer;
    begin
        // The suite runs as SUPER, which holds write on the Unmask Gate: the tier is held, so only the
        // Setup switch decides.
        Initialize();
        NameNo := CustomerFieldNo('Name');
        Helper.SetFieldAccess(Database::Customer, NameNo, "Bcmag Read Access"::Masked, 'PARTIAL', false);

        Helper.SetUnmaskTierEnabled(true);
        LibraryAssert.IsTrue(Policy.UnmaskGranted(), 'SUPER holds the tier while it is enabled');
        AssertAccess("Bcmag Read Access"::Clear, Verdict(NameNo, ProfileCode), 'the tier lifts Masked to Clear');
        LibraryAssert.IsTrue(StrPos(Lifts(), PairOf(NameNo)) > 0, 'the tier lift is noted');

        SetUnmaskRequest(false);
        AssertAccess("Bcmag Read Access"::Masked, Verdict(NameNo, ProfileCode), '"unmask": false declines the tier');
        LibraryAssert.AreEqual('', Lifts(), 'no lift under the opt-out');

        NeutralRequest();
        Helper.SetUnmaskTierEnabled(false);
        Clear(Policy);
        LibraryAssert.IsFalse(Policy.UnmaskGranted(), 'a disabled tier is never held');
        AssertAccess("Bcmag Read Access"::Masked, Verdict(NameNo, ProfileCode), 'a disabled tier lifts nothing');

        Helper.UnexposeField(Database::Customer, NameNo);
    end;

    [Test]
    procedure UnmaskTierNeverLiftsHidden()
    var
        ProfileCode: Code[20];
        NameNo: Integer;
    begin
        Initialize();
        NameNo := CustomerFieldNo('Name');
        Helper.SetFieldAccess(Database::Customer, NameNo, "Bcmag Read Access"::Hidden, '', false);
        Helper.SetUnmaskTierEnabled(true);

        AssertAccess("Bcmag Read Access"::Hidden, Verdict(NameNo, ProfileCode), 'the tier lifts Masked only, never Hidden');
        LibraryAssert.AreEqual('', Lifts(), 'nothing is lifted');

        Helper.SetUnmaskTierEnabled(false);
        Helper.UnexposeField(Database::Customer, NameNo);
    end;

    [Test]
    procedure UnmaskTierDoesNotOverrideAMaskingFieldException()
    var
        Policy: Codeunit "Bcmag Field Policy";
        ProfileCode: Code[20];
        NameNo: Integer;
    begin
        // Final-review I1: a per-user exception that masks a field is the administrator's targeted
        // choice; the blanket tier (held here as SUPER with the switch on) must not lift it to Clear.
        Initialize();
        NameNo := CustomerFieldNo('Name');
        Helper.SetFieldAccess(Database::Customer, NameNo, "Bcmag Read Access"::Clear, '', false);
        Helper.AddUserException(Scope::Field, "Bcmag Data Class"::CustomerContent, Database::Customer, NameNo, "Bcmag Read Access"::Masked, 'PARTIAL', 0DT);
        Helper.SetUnmaskTierEnabled(true);

        LibraryAssert.IsTrue(Policy.UnmaskGranted(), 'the tier is held');
        AssertAccess("Bcmag Read Access"::Masked, Policy.ReadVerdict(Database::Customer, NameNo, ProfileCode), 'the masking exception beats the tier');
        LibraryAssert.AreEqual('PARTIAL', Format(ProfileCode), 'the exception''s profile applies');
        LibraryAssert.AreEqual('', Lifts(), 'nothing is lifted');

        Helper.SetUnmaskTierEnabled(false);
        Helper.ClearUserExceptions();
        Helper.UnexposeField(Database::Customer, NameNo);
    end;

    [Test]
    procedure UnmaskTierDoesNotOverrideARemaskingException()
    var
        ProfileCode: Code[20];
        NameNo: Integer;
    begin
        // Baseline Masked/PARTIAL, the caller's exception Masked/REDACT, tier on: the exception decided
        // the field, so it stays Masked under the exception's profile.
        Initialize();
        NameNo := CustomerFieldNo('Name');
        SeedProfileKinds();
        Helper.SetFieldAccess(Database::Customer, NameNo, "Bcmag Read Access"::Masked, 'PARTIAL', false);
        Helper.AddUserException(Scope::Field, "Bcmag Data Class"::CustomerContent, Database::Customer, NameNo, "Bcmag Read Access"::Masked, 'REDACT', 0DT);
        Helper.SetUnmaskTierEnabled(true);

        AssertAccess("Bcmag Read Access"::Masked, Verdict(NameNo, ProfileCode), 'the re-masking exception beats the tier');
        LibraryAssert.AreEqual('REDACT', Format(ProfileCode), 'the exception''s profile applies');
        LibraryAssert.AreEqual('', Lifts(), 'nothing is lifted');

        Helper.SetUnmaskTierEnabled(false);
        Helper.ClearUserExceptions();
        Helper.UnexposeField(Database::Customer, NameNo);
    end;

    [Test]
    procedure UnmaskTierDoesNotOverrideAMaskingClassificationException()
    var
        FieldRec: Record Field;
        ProfileCode: Code[20];
        NameNo: Integer;
    begin
        // The same holds for a classification-scope exception that matched the field.
        Initialize();
        NameNo := CustomerFieldNo('Name');
        FieldRec.Get(Database::Customer, NameNo);
        Helper.SetFieldAccess(Database::Customer, NameNo, "Bcmag Read Access"::Clear, '', false);
        Helper.AddUserException(Scope::Classification, PolicyDefaults.DataClassOf(FieldRec), 0, 0, "Bcmag Read Access"::Masked, 'PARTIAL', 0DT);
        Helper.SetUnmaskTierEnabled(true);

        AssertAccess("Bcmag Read Access"::Masked, Verdict(NameNo, ProfileCode), 'the classification exception beats the tier');
        LibraryAssert.AreEqual('', Lifts(), 'nothing is lifted');

        Helper.SetUnmaskTierEnabled(false);
        Helper.ClearUserExceptions();
        Helper.UnexposeField(Database::Customer, NameNo);
    end;

    // ---- lift notes and marker -------------------------------------------------------------------

    [Test]
    procedure LiftNotesAreDistinctBoundedAndResetPerRequest()
    var
        Ctx: Codeunit "Bcmag Op Runner Context";
        Policy: Codeunit "Bcmag Field Policy";
        Parts: List of [Text];
        LastPart: Text;
        i, Omitted: Integer;
    begin
        NeutralRequest();
        Ctx.NoteLift(18, 9);
        Ctx.NoteLift(18, 102);
        Ctx.NoteLift(18, 9);
        LibraryAssert.AreEqual('18:9,18:102', Ctx.LiftedFieldsText(), 'distinct table:field pairs in note order');

        // Large table numbers are written invariantly (no thousands separator).
        NeutralRequest();
        Ctx.NoteLift(94105, 12);
        LibraryAssert.AreEqual('94105:12', Ctx.LiftedFieldsText(), 'invariant number format');

        for i := 1 to 100 do
            Ctx.NoteLift(94105, i);
        LibraryAssert.IsTrue(StrLen(Ctx.LiftedFieldsText()) <= 250, 'the lift text is bounded to 250 characters');
        // 100 distinct pairs do not fit: whole pairs are kept and ",+N" says how many were left out.
        Parts := Ctx.LiftedFieldsText().Split(',');
        LastPart := Parts.Get(Parts.Count());
        LibraryAssert.IsTrue(LastPart.StartsWith('+'), 'an overflowing list ends with the ",+N" marker, got ' + Ctx.LiftedFieldsText());
        LibraryAssert.IsTrue(Evaluate(Omitted, CopyStr(LastPart, 2)), 'N is a number');
        LibraryAssert.IsTrue(Omitted > 0, 'some pairs were left out');
        LibraryAssert.AreEqual(100, (Parts.Count() - 1) + Omitted, 'the kept pairs plus N account for every lift');
        LibraryAssert.AreEqual('94105:12', Parts.Get(1), 'the earliest lifts are the ones kept');

        NeutralRequest();
        LibraryAssert.AreEqual('', Ctx.LiftedFieldsText(), 'SetRequest clears the lift list');

        LibraryAssert.AreEqual('[field-masked] ', Policy.MaskedMarker(), 'the masked marker');
    end;

    // ---- helpers ---------------------------------------------------------------------------------

    local procedure Initialize()
    begin
        Helper.ConfigureOpenMode(); // AllFields + Unmask tier off
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::ByClassification);
        Helper.ClearUserExceptions();
        NeutralRequest();
    end;

    // A fresh policy instance per verdict, so no cache from an earlier step can answer.
    local procedure Verdict(FieldNo: Integer; var ProfileCode: Code[20]): Enum "Bcmag Read Access"
    var
        Policy: Codeunit "Bcmag Field Policy";
    begin
        exit(Policy.ReadVerdict(Database::Customer, FieldNo, ProfileCode));
    end;

    // The profile kinds the opt-out tie ranks: the shipped defaults (inserted only when missing), then
    // the three codes pinned to their shipped kinds in case an administrator changed them in this company.
    local procedure SeedProfileKinds()
    begin
        PolicyDefaults.SeedFieldPolicyDefaults();
        Helper.UpsertMaskProfile('PARTIAL', "Bcmag Mask Kind"::KeepLast, 0, 2, 4, false);
        Helper.UpsertMaskProfile('HASH', "Bcmag Mask Kind"::Hash, 0, 0, 4, false);
        Helper.UpsertMaskProfile('REDACT', "Bcmag Mask Kind"::Fixed, 0, 0, 4, false);
    end;

    local procedure NeutralRequest()
    var
        Ctx: Codeunit "Bcmag Op Runner Context";
        Data: JsonObject;
    begin
        Ctx.SetRequest('query', Data);
    end;

    local procedure SetUnmaskRequest(Unmask: Boolean)
    var
        Ctx: Codeunit "Bcmag Op Runner Context";
        Data: JsonObject;
    begin
        Data.Add('unmask', Unmask);
        Ctx.SetRequest('query', Data);
    end;

    local procedure Lifts(): Text
    var
        Ctx: Codeunit "Bcmag Op Runner Context";
    begin
        exit(Ctx.LiftedFieldsText());
    end;

    local procedure PairOf(FieldNo: Integer): Text
    begin
        exit(Format(Database::Customer, 0, 9) + ':' + Format(FieldNo, 0, 9));
    end;

    local procedure RestoreBuiltInRule(DataClass: Enum "Bcmag Data Class")
    var
        Access: Enum "Bcmag Read Access";
        ProfileCode: Code[20];
    begin
        PolicyDefaults.BuiltInRule(DataClass, Access, ProfileCode);
        Helper.SetClassificationRule(DataClass, Access, ProfileCode);
    end;

    local procedure InsertException(ExcScope: Option Classification,Field; TableId: Integer; FieldNo: Integer; ValidFrom: DateTime; ValidUntil: DateTime)
    var
        ExcRow: Record "Bcmag Access Exception";
    begin
        ExcRow.Init();
        ExcRow."User Security ID" := UserSecurityId();
        ExcRow.Scope := ExcScope;
        ExcRow."Table Id" := TableId;
        ExcRow."Field No." := FieldNo;
        ExcRow."Read Access" := ExcRow."Read Access"::Clear;
        ExcRow."Valid From" := ValidFrom;
        ExcRow."Valid Until" := ValidUntil;
        ExcRow.Insert();
    end;

    local procedure CustomerFieldNo(TargetName: Text): Integer
    var
        FieldRec: Record Field;
    begin
        FieldRec.SetRange(TableNo, Database::Customer);
        FieldRec.SetRange(FieldName, TargetName);
        LibraryAssert.IsTrue(FieldRec.FindFirst(), StrSubstNo('Customer must have a "%1" field', TargetName));
        exit(FieldRec."No.");
    end;

    local procedure AssertAccess(Expected: Enum "Bcmag Read Access"; Actual: Enum "Bcmag Read Access"; Msg: Text)
    begin
        LibraryAssert.AreEqual(Expected.AsInteger(), Actual.AsInteger(), Msg);
    end;
}
