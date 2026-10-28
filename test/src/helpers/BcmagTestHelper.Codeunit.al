codeunit 94320 "Bcmag Test Helper"
{
    // Shared helpers for the Wicket test suite: exposure-mode configuration, single-row
    // allowlist enrolment, and Fail-document accessors (the operation handlers return a Fail
    // JsonObject carrying {status,type,title,detail,suggest?}).

    procedure ConfigureOpenMode()
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.GetSingleton();
        Setup.Mode := Setup.Mode::Open;
        Setup."Allow Invoke In Open Mode" := false;
        Setup."Require ETag On Writes" := false;
        // The suite runs in a real company whose administrator may have switched the endpoint to
        // read-only: every baseline starts writable; tests of the switch opt in via SetReadOnlyMode.
        Setup."Read-Only Mode" := false;
        // Pin the v1.1 field-policy baseline (a fresh singleton defaults to ByClassification):
        // tests opt in to field restrictions explicitly via SetFieldPolicyMode.
        Setup."Field Policy Mode" := Setup."Field Policy Mode"::AllFields;
        PinWritePolicyBaseline(Setup);
        Setup.Modify(true);
        ResetFieldPolicyState();
    end;

    procedure ConfigureAllowlistedMode()
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.GetSingleton();
        Setup.Mode := Setup.Mode::Allowlisted;
        Setup."Allow Invoke In Open Mode" := false;
        Setup."Require ETag On Writes" := false;
        // The suite runs in a real company whose administrator may have switched the endpoint to
        // read-only: every baseline starts writable; tests of the switch opt in via SetReadOnlyMode.
        Setup."Read-Only Mode" := false;
        // Pin the v1.1 field-policy baseline — see ConfigureOpenMode.
        Setup."Field Policy Mode" := Setup."Field Policy Mode"::AllFields;
        PinWritePolicyBaseline(Setup);
        Setup.Modify(true);
        ResetFieldPolicyState();
    end;

    // The field-masking baseline every test starts from (both Configure* baselines call it, and so every
    // masking test codeunit's initializer). Several dispatcher tests COMMIT policy state (a masked
    // Customer.Name, user exceptions, Describe Restricted Fields, changed rules) and restore it only at
    // their end; if one fails mid-test on a first run, that state would otherwise cascade into every
    // later test and codeunit. So this puts the policy back, not just the mode:
    //   - the field rows the suite creates (Customer, and the Procedure Catalog fixture) are deleted;
    //   - the caller's exceptions are removed;
    //   - the classification rules and the five shipped mask profiles are re-seeded from the built-ins
    //     (deleted first, so a modified row comes back with its shipped values; T-* test profiles stay);
    //   - the Unmask tier is off (SUPER would otherwise lift every mask) and Describe Restricted Fields
    //     is off;
    //   - the Op Runner Context carries a neutral request (no "unmask" member, no lifts noted).
    // The mode itself is left to the caller (Configure* pin AllFields).
    procedure ResetFieldPolicyState()
    var
        Setup: Record "Bcmag Setup";
        FieldExposure: Record "Bcmag Field Exposure";
        Rule: Record "Bcmag Classification Rule";
        Profile: Record "Bcmag Mask Profile";
        PolicyDefaults: Codeunit "Bcmag Policy Defaults";
        Ctx: Codeunit "Bcmag Op Runner Context";
        NeutralData: JsonObject;
    begin
        FieldExposure.SetFilter("Table Id", '%1|%2', Database::Customer, Database::"Bcmag Procedure Catalog");
        if not FieldExposure.IsEmpty() then
            FieldExposure.DeleteAll();
        ClearUserExceptions();
        if not Rule.IsEmpty() then
            Rule.DeleteAll();
        Profile.SetFilter(Code, '%1|%2|%3|%4|%5', 'PARTIAL', 'EMAIL', 'REDACT', 'HASH', 'NULL');
        if not Profile.IsEmpty() then
            Profile.DeleteAll();
        PolicyDefaults.SeedFieldPolicyDefaults();
        Setup.GetSingleton();
        if Setup."Unmask Tier Enabled" or Setup."Describe Restricted Fields" then begin
            Setup."Unmask Tier Enabled" := false;
            Setup."Describe Restricted Fields" := false;
            Setup.Modify(true);
        end;
        Ctx.SetRequest('query', NeutralData);
    end;

    // A fresh singleton (the test database is a fresh install) starts with the safe write-policy
    // defaults — a key required for action/invoke, trigger bypass refused. The suite predates both and
    // relies on keyless calls and init:false, so the Configure* baselines pin the upgrade-compatible
    // values; tests of the policies themselves opt in through the setters below.
    local procedure PinWritePolicyBaseline(var Setup: Record "Bcmag Setup")
    begin
        Setup."Require Key For Actions" := false;
        Setup."Allow Trigger Bypass" := true;
        // Every baseline starts with API routing off; the API catalog tests opt in via SetApiRouting.
        Setup."API Routing" := Setup."API Routing"::Off;
        // The suite runs as SUPER (TestPermissions = Disabled), and SUPER holds every table permission —
        // including write on the Unmask Gate. With the tier honored, every Masked field would read Clear
        // and masking could not be tested at all, so the baseline switches the tier off; tests of the
        // tier itself opt in via SetUnmaskTierEnabled.
        Setup."Unmask Tier Enabled" := false;
    end;

    procedure SetUnmaskTierEnabled(Value: Boolean)
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.GetSingleton();
        Setup."Unmask Tier Enabled" := Value;
        Setup.Modify(true);
    end;

    procedure SetApiRouting(Routing: Enum "Bcmag Api Routing")
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.GetSingleton();
        Setup."API Routing" := Routing;
        Setup.Modify(true);
    end;

    procedure SetRequireKeyForActions(Value: Boolean)
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.GetSingleton();
        Setup."Require Key For Actions" := Value;
        Setup.Modify(true);
    end;

    procedure SetAllowTriggerBypass(Value: Boolean)
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.GetSingleton();
        Setup."Allow Trigger Bypass" := Value;
        Setup.Modify(true);
    end;

    // Enrol an Action Catalog row (enabled), replacing any prior row.
    procedure EnrolAction(ActionCode: Code[50]; WrapperCodeunitId: Integer; PreviewSupported: Boolean)
    var
        Catalog: Record "Bcmag Action Catalog";
    begin
        if Catalog.Get(ActionCode) then
            Catalog.Delete();
        Catalog.Init();
        Catalog."Action Code" := ActionCode;
        Catalog."Wrapper Codeunit Id" := WrapperCodeunitId;
        Catalog."Preview Supported" := PreviewSupported;
        Catalog."Allow Run" := true;
        Catalog.Insert();
    end;

    procedure SetFieldPolicyMode(Mode: Enum "Bcmag Field Policy Mode")
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.GetSingleton();
        Setup."Field Policy Mode" := Mode;
        Setup.Modify(true);
    end;

    // Kept from the switch era: true → the CustomerContent rule is Clear, false → Hidden.
    procedure SetExposeCustomerContent(Value: Boolean)
    begin
        if Value then
            SetClassificationRule("Bcmag Data Class"::CustomerContent, "Bcmag Read Access"::Clear, '')
        else
            SetClassificationRule("Bcmag Data Class"::CustomerContent, "Bcmag Read Access"::Hidden, '');
    end;

    // Upsert the rule row for one classification (consulted in ByClassification mode).
    procedure SetClassificationRule(DataClass: Enum "Bcmag Data Class"; Access: Enum "Bcmag Read Access"; ProfileCode: Code[20])
    var
        Rule: Record "Bcmag Classification Rule";
    begin
        if not Rule.Get(DataClass) then begin
            Rule.Init();
            Rule."Data Class" := DataClass;
            Rule.Insert();
        end;
        Rule."Read Access" := Access;
        Rule."Mask Profile" := ProfileCode;
        Rule.Modify();
    end;

    // Upsert a mask profile; Mask Char and Fixed Text keep their table defaults ('*', '[redacted]').
    procedure UpsertMaskProfile(ProfileCode: Code[20]; Kind: Enum "Bcmag Mask Kind"; KeepFirst: Integer; KeepLast: Integer; MinHidden: Integer; PreserveLength: Boolean)
    var
        Profile: Record "Bcmag Mask Profile";
    begin
        if not Profile.Get(ProfileCode) then begin
            Profile.Init();
            Profile.Code := ProfileCode;
            Profile.Insert();
        end;
        Profile.Kind := Kind;
        Profile."Keep First" := KeepFirst;
        Profile."Keep Last" := KeepLast;
        Profile."Min Hidden" := MinHidden;
        Profile."Preserve Length" := PreserveLength;
        Profile.Modify();
    end;

    // Add a per-user exception for the CURRENT user (the suite's caller). Scope Classification uses
    // DataClass; Scope Field uses TableId/FieldNo. Valid From is left blank (already active); a blank
    // ValidUntil (0DT) is open-ended.
    procedure AddUserException(Scope: Option Classification,Field; DataClass: Enum "Bcmag Data Class"; TableId: Integer; FieldNo: Integer; Access: Enum "Bcmag Read Access"; ProfileCode: Code[20]; ValidUntil: DateTime)
    var
        ExcRow: Record "Bcmag Access Exception";
    begin
        ExcRow.Init();
        ExcRow."User Security ID" := UserSecurityId();
        ExcRow.Scope := Scope;
        ExcRow."Data Class" := DataClass;
        ExcRow."Table Id" := TableId;
        ExcRow."Field No." := FieldNo;
        ExcRow."Read Access" := Access;
        ExcRow."Mask Profile" := ProfileCode;
        ExcRow."Valid Until" := ValidUntil;
        ExcRow.Insert();
    end;

    // Remove the current user's exceptions (other users' rows cannot affect this caller's verdict).
    procedure ClearUserExceptions()
    var
        ExcRow: Record "Bcmag Access Exception";
    begin
        ExcRow.SetRange("User Security ID", UserSecurityId());
        if not ExcRow.IsEmpty() then
            ExcRow.DeleteAll();
    end;

    procedure SetDescribeRestrictedFields(Value: Boolean)
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.GetSingleton();
        Setup."Describe Restricted Fields" := Value;
        Setup.Modify(true);
    end;

    procedure SetReadOnlyMode(Value: Boolean)
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.GetSingleton();
        Setup."Read-Only Mode" := Value;
        Setup.Modify(true);
    end;

    // Enrol a field-exposure override row, replacing any prior row. Kept from the boolean era:
    // AllowRead → Clear, otherwise Hidden.
    procedure ExposeField(TableId: Integer; FieldNo: Integer; AllowRead: Boolean; AllowWrite: Boolean)
    begin
        if AllowRead then
            SetFieldAccess(TableId, FieldNo, "Bcmag Read Access"::Clear, '', AllowWrite)
        else
            SetFieldAccess(TableId, FieldNo, "Bcmag Read Access"::Hidden, '', AllowWrite);
    end;

    // Enrol a field-exposure override row with a tri-state verdict, replacing any prior row.
    procedure SetFieldAccess(TableId: Integer; FieldNo: Integer; Access: Enum "Bcmag Read Access"; ProfileCode: Code[20]; AllowWrite: Boolean)
    var
        FieldExposure: Record "Bcmag Field Exposure";
    begin
        if FieldExposure.Get(TableId, FieldNo) then
            FieldExposure.Delete();
        FieldExposure.Init();
        FieldExposure."Table Id" := TableId;
        FieldExposure."Field No." := FieldNo;
        FieldExposure."Read Access" := Access;
        FieldExposure."Mask Profile" := ProfileCode;
        FieldExposure."Allow Write" := AllowWrite;
        FieldExposure.Insert();
    end;

    procedure UnexposeField(TableId: Integer; FieldNo: Integer)
    var
        FieldExposure: Record "Bcmag Field Exposure";
    begin
        if FieldExposure.Get(TableId, FieldNo) then
            FieldExposure.Delete();
    end;

    procedure RequireEtagOnWrites(Require: Boolean)
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.GetSingleton();
        Setup."Require ETag On Writes" := Require;
        Setup.Modify(true);
    end;

    procedure SetMaxSelectFields(Max: Integer)
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.GetSingleton();
        Setup."Max Select Fields" := Max;
        Setup.Modify(true);
    end;

    // Enrol a table in the exposure allowlist with the requested rights, replacing any prior row.
    procedure ExposeTable(TableId: Integer; AllowRead: Boolean; AllowInsert: Boolean; AllowModify: Boolean; AllowDelete: Boolean)
    var
        Exposure: Record "Bcmag Exposure";
    begin
        if Exposure.Get(Exposure."Object Type"::Table, TableId) then
            Exposure.Delete();
        Exposure.Init();
        Exposure."Object Type" := Exposure."Object Type"::Table;
        Exposure."Object Id" := TableId;
        Exposure."Allow Read" := AllowRead;
        Exposure."Allow Insert" := AllowInsert;
        Exposure."Allow Modify" := AllowModify;
        Exposure."Allow Delete" := AllowDelete;
        Exposure.Insert();
    end;

    procedure UnexposeTable(TableId: Integer)
    var
        Exposure: Record "Bcmag Exposure";
    begin
        if Exposure.Get(Exposure."Object Type"::Table, TableId) then
            Exposure.Delete();
    end;

    procedure ExposeCodeunitInvoke(CodeunitId: Integer)
    var
        Exposure: Record "Bcmag Exposure";
    begin
        if Exposure.Get(Exposure."Object Type"::Codeunit, CodeunitId) then
            Exposure.Delete();
        Exposure.Init();
        Exposure."Object Type" := Exposure."Object Type"::Codeunit;
        Exposure."Object Id" := CodeunitId;
        Exposure."Allow Invoke" := true;
        Exposure.Insert();
    end;

    procedure UnexposeCodeunit(CodeunitId: Integer)
    var
        Exposure: Record "Bcmag Exposure";
    begin
        if Exposure.Get(Exposure."Object Type"::Codeunit, CodeunitId) then
            Exposure.Delete();
    end;

    // Enrol an invokable procedure in the Procedure Catalog (deny-by-default registry).
    procedure EnrolProcedure(LogicalCodeunitId: Integer; ProcedureName: Text; WrapperCodeunitId: Integer; ReturnShape: Enum "Bcmag Return Shape")
    var
        Catalog: Record "Bcmag Procedure Catalog";
    begin
        if Catalog.Get(LogicalCodeunitId, ProcedureName) then
            Catalog.Delete();
        Catalog.Init();
        Catalog."Logical Codeunit Id" := LogicalCodeunitId;
        Catalog."Procedure Name" := CopyStr(ProcedureName, 1, MaxStrLen(Catalog."Procedure Name"));
        Catalog."Wrapper Codeunit Id" := WrapperCodeunitId;
        Catalog."Return Shape" := ReturnShape;
        Catalog."Allow Run" := true;
        Catalog.Insert();
    end;

    procedure RemoveProcedure(LogicalCodeunitId: Integer; ProcedureName: Text)
    var
        Catalog: Record "Bcmag Procedure Catalog";
    begin
        if Catalog.Get(LogicalCodeunitId, ProcedureName) then
            Catalog.Delete();
    end;

    // Fixture writes leave the test in an open write transaction, and AL forbids two things there.
    // Codeunit.Run with a return value — the dispatcher's Op Runner boundary and the invoke op's
    // wrapper call — is documented as "if you're already in a transaction you must commit first",
    // and an ON-PREM server (the CI container) additionally refuses any database write inside a try
    // function. An early CI run failed 17 tests on exactly these two rules. Call this
    // after seeding and before the call under test; the test runner's isolation still rolls every
    // commit back at the end of the codeunit.
    procedure CommitFixtures()
    begin
        Commit();
    end;

    // Build a minimal valid envelope { id, issuedAt, origin, data } for dispatcher-level tests.
    procedure Envelope(Data: JsonObject) Body: JsonObject
    begin
        Body.Add('id', DelChr(LowerCase(Format(CreateGuid())), '<>', '{}'));
        Body.Add('issuedAt', Format(CurrentDateTime(), 0, 9));
        Body.Add('origin', 'wicket.test');
        Body.Add('data', Data);
    end;

    // Envelope variant carrying the optional idempotencyKey member.
    procedure EnvelopeWithKey(Data: JsonObject; IdemKey: Text) Body: JsonObject
    begin
        Body := Envelope(Data);
        Body.Add('idempotencyKey', IdemKey);
    end;

    // Unique-per-run idempotency key: idempotency log rows survive across test runs in the same
    // database, so a hardcoded key would collide with its own snapshot from a previous run.
    procedure NewIdemKey() IdemKey: Text
    begin
        IdemKey := 'idem-' + DelChr(LowerCase(Format(CreateGuid())), '<>', '{}');
    end;

    // Wire Sales & Receivables Setup to a No. Series that permits manual customer numbers, so
    // validating Customer."No." with a caller-supplied value never trips a No. Series error.
    procedure EnsureManualCustomerNos()
    var
        SalesSetup: Record "Sales & Receivables Setup";
        NoSeries: Record "No. Series";
        SeriesCode: Code[20];
    begin
        SeriesCode := 'BCMAGTEST';
        if not NoSeries.Get(SeriesCode) then begin
            NoSeries.Init();
            NoSeries.Code := SeriesCode;
            NoSeries.Description := 'Wicket test (manual)';
            NoSeries."Manual Nos." := true;
            NoSeries."Default Nos." := false;
            NoSeries.Insert();
        end else
            if not NoSeries."Manual Nos." then begin
                NoSeries."Manual Nos." := true;
                NoSeries.Modify();
            end;

        if not SalesSetup.Get() then begin
            SalesSetup.Init();
            SalesSetup.Insert();
        end;
        SalesSetup."Customer Nos." := SeriesCode;
        SalesSetup.Modify();
    end;

    // Turn on async delivery and stash a dummy Azure credential so IsConfigured() returns true. The
    // ENQUEUE path never calls Azure (only IsConfigured + a local URL build), so this is enough to
    // exercise validation and the dispatcher fork without a live storage account — only the WORKER's
    // upload needs a sandbox.
    procedure ConfigureAsync()
    var
        Setup: Record "Bcmag Setup";
        AzureClient: Codeunit "Bcmag Azure Client";
    begin
        Setup.GetSingleton();
        Setup."Async Enabled" := true;
        Setup."Azure Storage Account" := 'bcmagtest';
        Setup."Azure Blob Container" := 'packages';
        Setup."Azure Auth Mode" := Setup."Azure Auth Mode"::SharedKey;
        Setup."Download Mode" := Setup."Download Mode"::ServiceSas; // mints a local HMAC SAS from the dummy key — no network (StreamProxy is refused: unbuilt)
        Setup."Default Package Format" := Setup."Default Package Format"::Ndjson;
        Setup."Max Active Requests" := 20;
        Setup."Max Schedule Ahead Days" := 30;
        Setup.Modify(true);
        AzureClient.SetCredential('ZHVtbXk='); // base64("dummy") — never used by the enqueue path
    end;

    procedure DisableAsync()
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.GetSingleton();
        Setup."Async Enabled" := false;
        Setup.Modify(true);
    end;

    // Read a Temp Blob back as UTF-8 text (used to assert package contents).
    procedure TempBlobToText(var TempBlob: Codeunit "Temp Blob") Content: Text
    var
        InStr: InStream;
        Line: Text;
        Builder: TextBuilder;
    begin
        TempBlob.CreateInStream(InStr, TextEncoding::UTF8);
        while not InStr.EOS() do begin
            InStr.ReadText(Line);
            Builder.AppendLine(Line);
        end;
        exit(Builder.ToText());
    end;

    procedure TypeOf(Fail: JsonObject): Text
    var
        Tok: JsonToken;
    begin
        if Fail.Get('type', Tok) then
            exit(Tok.AsValue().AsText());
        exit('');
    end;

    procedure StatusOf(Fail: JsonObject): Integer
    var
        Tok: JsonToken;
    begin
        if Fail.Get('status', Tok) then
            exit(Tok.AsValue().AsInteger());
        exit(0);
    end;

    procedure DetailOf(Fail: JsonObject): Text
    var
        Tok: JsonToken;
    begin
        if Fail.Get('detail', Tok) then
            exit(Tok.AsValue().AsText());
        exit('');
    end;

    // Pull the typed payload that a query/insert/etc. returns under "value".
    procedure ValueArray(Response: JsonObject) Arr: JsonArray
    var
        Tok: JsonToken;
    begin
        if Response.Get('value', Tok) then
            Arr := Tok.AsArray();
    end;

    procedure ValueObject(Response: JsonObject) Obj: JsonObject
    var
        Tok: JsonToken;
    begin
        if Response.Get('value', Tok) then
            Obj := Tok.AsObject();
    end;

    procedure TextField(Obj: JsonObject; Name: Text): Text
    var
        Tok: JsonToken;
    begin
        if Obj.Get(Name, Tok) then
            exit(Tok.AsValue().AsText());
        exit('');
    end;
}
