codeunit 94333 "Bcmag Mask Model Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    // The field-masking data model: the install/upgrade seed of classification rules and mask
    // profiles (idempotent, never overwriting an administrator's choice), the built-in defaults the
    // verdict engine falls back to when a rule row is missing, the single classification name map,
    // and the permission-set shape of the Unmask tier (a data grant held apart from Admin).

    var
        PolicyDefaults: Codeunit "Bcmag Policy Defaults";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";
        BcmagAppIdTok: Label '4057cf1f-1b34-409a-a570-c6fdf625c434', Locked = true;

    // ---- seed ------------------------------------------------------------------------------------

    [Test]
    procedure SeedOnEmptyTablesInsertsBuiltInDefaults()
    var
        Rule: Record "Bcmag Classification Rule";
        Profile: Record "Bcmag Mask Profile";
    begin
        ClearPolicyTables();

        PolicyDefaults.SeedFieldPolicyDefaults();

        LibraryAssert.AreEqual(7, Rule.Count(), 'one rule row per data classification');
        AssertRule("Bcmag Data Class"::CustomerContent, "Bcmag Read Access"::Clear, '');
        AssertRule("Bcmag Data Class"::SystemMetadata, "Bcmag Read Access"::Clear, '');
        AssertRule("Bcmag Data Class"::EndUserIdentifiableInformation, "Bcmag Read Access"::Masked, 'PARTIAL');
        AssertRule("Bcmag Data Class"::EndUserPseudonymousIdentifiers, "Bcmag Read Access"::Masked, 'PARTIAL');
        AssertRule("Bcmag Data Class"::ToBeClassified, "Bcmag Read Access"::Hidden, '');
        AssertRule("Bcmag Data Class"::OrganizationIdentifiableInformation, "Bcmag Read Access"::Hidden, '');
        AssertRule("Bcmag Data Class"::AccountData, "Bcmag Read Access"::Hidden, '');

        LibraryAssert.AreEqual(5, Profile.Count(), 'five built-in mask profiles');
        LibraryAssert.IsTrue(Profile.Get('PARTIAL'), 'PARTIAL profile missing');
        LibraryAssert.AreEqual("Bcmag Mask Kind"::KeepLast.AsInteger(), Profile.Kind.AsInteger(), 'PARTIAL kind');
        LibraryAssert.AreEqual(2, Profile."Keep Last", 'PARTIAL keeps the last 2');
        LibraryAssert.AreEqual(0, Profile."Keep First", 'PARTIAL keeps nothing at the front');
        LibraryAssert.AreEqual(4, Profile."Min Hidden", 'PARTIAL min hidden');
        LibraryAssert.AreEqual('*', Profile."Mask Char", 'PARTIAL mask char');
        LibraryAssert.IsFalse(Profile."Preserve Length", 'PARTIAL must not preserve length');
        AssertProfileKind('EMAIL', "Bcmag Mask Kind"::Email);
        AssertProfileKind('REDACT', "Bcmag Mask Kind"::Fixed);
        AssertProfileKind('HASH', "Bcmag Mask Kind"::Hash);
        AssertProfileKind('NULL', "Bcmag Mask Kind"::Null);
        Profile.Get('REDACT');
        LibraryAssert.AreEqual('[redacted]', Profile."Fixed Text", 'REDACT fixed text');
    end;

    [Test]
    procedure SeedIsIdempotentAndKeepsAdminChanges()
    var
        Rule: Record "Bcmag Classification Rule";
        Profile: Record "Bcmag Mask Profile";
    begin
        ClearPolicyTables();
        PolicyDefaults.SeedFieldPolicyDefaults();

        // An administrator tightens CustomerContent and widens PARTIAL.
        Rule.Get("Bcmag Data Class"::CustomerContent);
        Rule."Read Access" := Rule."Read Access"::Hidden;
        Rule.Modify();
        Profile.Get('PARTIAL');
        Profile."Keep Last" := 3;
        Profile.Modify();
        // ... and deletes one rule row (falls back to the built-in default; a re-seed restores it).
        Rule.Get("Bcmag Data Class"::AccountData);
        Rule.Delete();

        PolicyDefaults.SeedFieldPolicyDefaults();

        LibraryAssert.AreEqual(7, Rule.Count(), 're-seed must insert only the missing row');
        LibraryAssert.AreEqual(5, Profile.Count(), 're-seed must not duplicate profiles');
        AssertRule("Bcmag Data Class"::CustomerContent, "Bcmag Read Access"::Hidden, '');
        AssertRule("Bcmag Data Class"::AccountData, "Bcmag Read Access"::Hidden, '');
        Profile.Get('PARTIAL');
        LibraryAssert.AreEqual(3, Profile."Keep Last", 're-seed must not overwrite an admin-changed profile');

        // Leave the seeded posture behind: later tests in this codeunit must not inherit a Hidden
        // CustomerContent rule or a widened PARTIAL profile.
        ClearPolicyTables();
        PolicyDefaults.SeedFieldPolicyDefaults();
    end;

    // ---- built-in defaults and the name map ------------------------------------------------------

    [Test]
    procedure BuiltInRuleMatchesTheFreshInstallPosture()
    begin
        AssertBuiltIn("Bcmag Data Class"::CustomerContent, "Bcmag Read Access"::Clear, '');
        AssertBuiltIn("Bcmag Data Class"::SystemMetadata, "Bcmag Read Access"::Clear, '');
        AssertBuiltIn("Bcmag Data Class"::EndUserIdentifiableInformation, "Bcmag Read Access"::Masked, 'PARTIAL');
        AssertBuiltIn("Bcmag Data Class"::EndUserPseudonymousIdentifiers, "Bcmag Read Access"::Masked, 'PARTIAL');
        AssertBuiltIn("Bcmag Data Class"::ToBeClassified, "Bcmag Read Access"::Hidden, '');
        AssertBuiltIn("Bcmag Data Class"::OrganizationIdentifiableInformation, "Bcmag Read Access"::Hidden, '');
        AssertBuiltIn("Bcmag Data Class"::AccountData, "Bcmag Read Access"::Hidden, '');
    end;

    [Test]
    procedure ClassNamesAreInvariantIdentifiers()
    begin
        LibraryAssert.AreEqual('CustomerContent', PolicyDefaults.ClassName("Bcmag Data Class"::CustomerContent), 'CustomerContent');
        LibraryAssert.AreEqual('ToBeClassified', PolicyDefaults.ClassName("Bcmag Data Class"::ToBeClassified), 'ToBeClassified');
        LibraryAssert.AreEqual('EndUserIdentifiableInformation', PolicyDefaults.ClassName("Bcmag Data Class"::EndUserIdentifiableInformation), 'EUII');
        LibraryAssert.AreEqual('AccountData', PolicyDefaults.ClassName("Bcmag Data Class"::AccountData), 'AccountData');
        LibraryAssert.AreEqual('EndUserPseudonymousIdentifiers', PolicyDefaults.ClassName("Bcmag Data Class"::EndUserPseudonymousIdentifiers), 'EUPI');
        LibraryAssert.AreEqual('OrganizationIdentifiableInformation', PolicyDefaults.ClassName("Bcmag Data Class"::OrganizationIdentifiableInformation), 'OII');
        LibraryAssert.AreEqual('SystemMetadata', PolicyDefaults.ClassName("Bcmag Data Class"::SystemMetadata), 'SystemMetadata');
    end;

    [Test]
    procedure DataClassOfReadsTheFieldClassification()
    var
        FieldRec: Record Field;
        Customer: Record Customer;
    begin
        // Customer.Name is CustomerContent (the describe test pins the same fact).
        FieldRec.Get(Database::Customer, Customer.FieldNo(Name));
        LibraryAssert.AreEqual("Bcmag Data Class"::CustomerContent.AsInteger(), PolicyDefaults.DataClassOf(FieldRec).AsInteger(), 'Customer.Name class');
        // Every Field classification maps through the explicit case, ordinal for ordinal.
        FieldRec.DataClassification := FieldRec.DataClassification::EndUserIdentifiableInformation;
        LibraryAssert.AreEqual("Bcmag Data Class"::EndUserIdentifiableInformation.AsInteger(), PolicyDefaults.DataClassOf(FieldRec).AsInteger(), 'EUII');
        FieldRec.DataClassification := FieldRec.DataClassification::AccountData;
        LibraryAssert.AreEqual("Bcmag Data Class"::AccountData.AsInteger(), PolicyDefaults.DataClassOf(FieldRec).AsInteger(), 'AccountData');
        FieldRec.DataClassification := FieldRec.DataClassification::SystemMetadata;
        LibraryAssert.AreEqual("Bcmag Data Class"::SystemMetadata.AsInteger(), PolicyDefaults.DataClassOf(FieldRec).AsInteger(), 'SystemMetadata');
    end;

    // ---- defaults of the new / changed fields ----------------------------------------------------

    [Test]
    procedure NewRowsStartWithTheIntendedDefaults()
    var
        Setup: Record "Bcmag Setup";
        FieldExposure: Record "Bcmag Field Exposure";
        Profile: Record "Bcmag Mask Profile";
    begin
        Setup.Init();
        LibraryAssert.IsTrue(Setup."Unmask Tier Enabled", 'a fresh Setup row honors the Unmask tier');
        FieldExposure.Init();
        LibraryAssert.AreEqual(FieldExposure."Read Access"::Clear.AsInteger(), FieldExposure."Read Access".AsInteger(), 'a field row defaults to Clear (an override row is usually a grant)');
        Profile.Init();
        LibraryAssert.AreEqual(4, Profile."Min Hidden", 'Min Hidden default');
        LibraryAssert.AreEqual('*', Profile."Mask Char", 'Mask Char default');
        LibraryAssert.AreEqual('[redacted]', Profile."Fixed Text", 'Fixed Text default');
    end;

    [Test]
    procedure HelperSettersMapOntoTheNewModel()
    var
        Rule: Record "Bcmag Classification Rule";
        FieldExposure: Record "Bcmag Field Exposure";
        Setup: Record "Bcmag Setup";
        Customer: Record Customer;
    begin
        // ExposeField keeps its boolean signature: read → Clear, no read → Hidden.
        Helper.ExposeField(Database::Customer, Customer.FieldNo(Name), true, false);
        FieldExposure.Get(Database::Customer, Customer.FieldNo(Name));
        LibraryAssert.AreEqual(FieldExposure."Read Access"::Clear.AsInteger(), FieldExposure."Read Access".AsInteger(), 'ExposeField(true) → Clear');
        Helper.ExposeField(Database::Customer, Customer.FieldNo(Name), false, false);
        FieldExposure.Get(Database::Customer, Customer.FieldNo(Name));
        LibraryAssert.AreEqual(FieldExposure."Read Access"::Hidden.AsInteger(), FieldExposure."Read Access".AsInteger(), 'ExposeField(false) → Hidden');
        Helper.UnexposeField(Database::Customer, Customer.FieldNo(Name));

        // SetExposeCustomerContent drives the CustomerContent rule row.
        Helper.SetExposeCustomerContent(false);
        Rule.Get("Bcmag Data Class"::CustomerContent);
        LibraryAssert.AreEqual(Rule."Read Access"::Hidden.AsInteger(), Rule."Read Access".AsInteger(), 'SetExposeCustomerContent(false) → Hidden');
        Helper.SetExposeCustomerContent(true);
        Rule.Get("Bcmag Data Class"::CustomerContent);
        LibraryAssert.AreEqual(Rule."Read Access"::Clear.AsInteger(), Rule."Read Access".AsInteger(), 'SetExposeCustomerContent(true) → Clear');

        // The Configure* baselines switch the Unmask tier off: the suite runs as SUPER, which holds
        // every table permission and would otherwise lift every masked field.
        Helper.ConfigureOpenMode();
        Setup.GetSingleton();
        LibraryAssert.IsFalse(Setup."Unmask Tier Enabled", 'the test baseline must switch the Unmask tier off');
        Helper.SetUnmaskTierEnabled(true);
        Setup.GetSingleton();
        LibraryAssert.IsTrue(Setup."Unmask Tier Enabled", 'SetUnmaskTierEnabled(true)');
        Helper.SetUnmaskTierEnabled(false);
    end;

    [Test]
    procedure UserExceptionHelpersScopeToTheCaller()
    var
        ExcRow: Record "Bcmag Access Exception";
        Customer: Record Customer;
        ValidUntil: DateTime;
        Scope: Option Classification,Field;
    begin
        Helper.ClearUserExceptions();
        ValidUntil := CurrentDateTime() + 3600000;
        Helper.AddUserException(Scope::Classification, "Bcmag Data Class"::EndUserIdentifiableInformation, 0, 0, "Bcmag Read Access"::Clear, '', ValidUntil);
        Helper.AddUserException(Scope::Field, "Bcmag Data Class"::CustomerContent, Database::Customer, Customer.FieldNo(Name), "Bcmag Read Access"::Masked, 'PARTIAL', 0DT);

        ExcRow.SetRange("User Security ID", UserSecurityId());
        LibraryAssert.AreEqual(2, ExcRow.Count(), 'two exceptions for the caller');
        ExcRow.SetRange(Scope, ExcRow.Scope::Field);
        LibraryAssert.IsTrue(ExcRow.FindFirst(), 'field-scope exception missing');
        LibraryAssert.AreEqual(Database::Customer, ExcRow."Table Id", 'field exception table');
        LibraryAssert.AreEqual(Customer.FieldNo(Name), ExcRow."Field No.", 'field exception field');
        LibraryAssert.AreEqual(ExcRow."Read Access"::Masked.AsInteger(), ExcRow."Read Access".AsInteger(), 'field exception access');
        LibraryAssert.AreEqual('PARTIAL', Format(ExcRow."Mask Profile"), 'field exception profile');

        Helper.ClearUserExceptions();
        ExcRow.Reset();
        ExcRow.SetRange("User Security ID", UserSecurityId());
        LibraryAssert.IsTrue(ExcRow.IsEmpty(), 'ClearUserExceptions must remove the caller''s rows');
    end;

    [Test]
    procedure CapabilitiesListsEveryClassificationRule()
    var
        OpCapabilities: Codeunit "Bcmag Op Capabilities";
        Data, Response, Fail, Value, FieldPolicyObj, Entry: JsonObject;
        Tok: JsonToken;
        Classifications: JsonArray;
        Cost, i: Integer;
        FoundEuii: Boolean;
    begin
        ClearPolicyTables();
        PolicyDefaults.SeedFieldPolicyDefaults();

        LibraryAssert.IsTrue(OpCapabilities.Run(Data, Response, Fail, Cost), 'capabilities should succeed');
        Value := Helper.ValueObject(Response);
        LibraryAssert.IsTrue(Value.Get('fieldPolicy', Tok), 'fieldPolicy missing');
        FieldPolicyObj := Tok.AsObject();
        LibraryAssert.IsFalse(FieldPolicyObj.Contains('exposedClassifications'), 'exposedClassifications is replaced by classifications');
        LibraryAssert.IsTrue(FieldPolicyObj.Get('classifications', Tok), 'classifications missing');
        Classifications := Tok.AsArray();
        LibraryAssert.AreEqual(7, Classifications.Count(), 'one entry per classification');
        for i := 0 to Classifications.Count() - 1 do begin
            Classifications.Get(i, Tok);
            Entry := Tok.AsObject();
            if Helper.TextField(Entry, 'name') = 'EndUserIdentifiableInformation' then begin
                FoundEuii := true;
                LibraryAssert.AreEqual('masked', Helper.TextField(Entry, 'access'), 'EUII access');
                LibraryAssert.AreEqual('PARTIAL', Helper.TextField(Entry, 'maskProfile'), 'EUII profile');
            end;
            if Helper.TextField(Entry, 'name') = 'AccountData' then
                LibraryAssert.AreEqual('hidden', Helper.TextField(Entry, 'access'), 'AccountData access');
            if Helper.TextField(Entry, 'name') = 'CustomerContent' then
                LibraryAssert.AreEqual('clear', Helper.TextField(Entry, 'access'), 'CustomerContent access');
        end;
        LibraryAssert.IsTrue(FoundEuii, 'EUII entry missing');
    end;

    // ---- permission sets -------------------------------------------------------------------------

    [Test]
    procedure UnmaskTierIsADataGrantHeldApartFromAdmin()
    var
        Perm: Record "Expanded Permission";
    begin
        // Unmasking is a data grant, not an administrative one: only "Wicket - Unmask" may write the
        // sentinel (the verdict engine asks WritePermission on it), and Admin must NOT include it.
        LibraryAssert.IsTrue(FindRow('Wicket - Unmask', Perm."Object Type"::"Table Data", Database::"Bcmag Unmask Gate", Perm),
            '"Wicket - Unmask" must grant tabledata on the Unmask Gate');
        LibraryAssert.AreEqual(Perm."Read Permission"::Yes, Perm."Read Permission", 'Unmask: Read');
        LibraryAssert.AreEqual(Perm."Insert Permission"::Yes, Perm."Insert Permission", 'Unmask: Insert');
        LibraryAssert.AreEqual(Perm."Modify Permission"::Yes, Perm."Modify Permission", 'Unmask: Modify');
        LibraryAssert.AreEqual(Perm."Delete Permission"::Yes, Perm."Delete Permission", 'Unmask: Delete');

        Clear(Perm);
        if FindRow('Wicket - Admin', Perm."Object Type"::"Table Data", Database::"Bcmag Unmask Gate", Perm) then begin
            LibraryAssert.AreNotEqual(Perm."Insert Permission"::Yes, Perm."Insert Permission", 'Admin must not write the Unmask Gate');
            LibraryAssert.AreNotEqual(Perm."Modify Permission"::Yes, Perm."Modify Permission", 'Admin must not write the Unmask Gate');
        end;
        // Admin still owns the policy tables themselves.
        LibraryAssert.IsTrue(FindRow('Wicket - Admin', Perm."Object Type"::"Table Data", Database::"Bcmag Classification Rule", Perm), 'Admin: rule tabledata');
        LibraryAssert.AreEqual(Perm."Insert Permission"::Yes, Perm."Insert Permission", 'Admin: rule Insert');
        LibraryAssert.IsTrue(FindRow('Wicket - Admin', Perm."Object Type"::"Table Data", Database::"Bcmag Access Exception", Perm), 'Admin: exception tabledata');
        LibraryAssert.AreEqual(Perm."Delete Permission"::Yes, Perm."Delete Permission", 'Admin: exception Delete');
        // Every caller reads the policy but cannot change it.
        LibraryAssert.IsTrue(FindRow('Wicket - Read', Perm."Object Type"::"Table Data", Database::"Bcmag Mask Profile", Perm), 'Read: profile tabledata');
        LibraryAssert.AreEqual(Perm."Read Permission"::Yes, Perm."Read Permission", 'Read: profile Read');
        LibraryAssert.AreNotEqual(Perm."Insert Permission"::Yes, Perm."Insert Permission", 'Read: profile Insert');
    end;

    // ---- helpers ---------------------------------------------------------------------------------

    local procedure ClearPolicyTables()
    var
        Rule: Record "Bcmag Classification Rule";
        Profile: Record "Bcmag Mask Profile";
    begin
        Rule.DeleteAll();
        Profile.DeleteAll();
    end;

    local procedure AssertRule(DataClass: Enum "Bcmag Data Class"; Access: Enum "Bcmag Read Access"; ProfileCode: Code[20])
    var
        Rule: Record "Bcmag Classification Rule";
        Name: Text;
    begin
        Name := PolicyDefaults.ClassName(DataClass);
        LibraryAssert.IsTrue(Rule.Get(DataClass), StrSubstNo('rule row for %1 missing', Name));
        LibraryAssert.AreEqual(Access.AsInteger(), Rule."Read Access".AsInteger(), StrSubstNo('rule access for %1', Name));
        LibraryAssert.AreEqual(ProfileCode, Rule."Mask Profile", StrSubstNo('rule profile for %1', Name));
    end;

    local procedure AssertBuiltIn(DataClass: Enum "Bcmag Data Class"; ExpectedAccess: Enum "Bcmag Read Access"; ExpectedProfile: Code[20])
    var
        Access: Enum "Bcmag Read Access";
        ProfileCode: Code[20];
    begin
        PolicyDefaults.BuiltInRule(DataClass, Access, ProfileCode);
        LibraryAssert.AreEqual(ExpectedAccess.AsInteger(), Access.AsInteger(), StrSubstNo('built-in access for %1', PolicyDefaults.ClassName(DataClass)));
        LibraryAssert.AreEqual(ExpectedProfile, ProfileCode, StrSubstNo('built-in profile for %1', PolicyDefaults.ClassName(DataClass)));
    end;

    local procedure AssertProfileKind(ProfileCode: Code[20]; Kind: Enum "Bcmag Mask Kind")
    var
        Profile: Record "Bcmag Mask Profile";
    begin
        LibraryAssert.IsTrue(Profile.Get(ProfileCode), StrSubstNo('profile %1 missing', ProfileCode));
        LibraryAssert.AreEqual(Kind.AsInteger(), Profile.Kind.AsInteger(), StrSubstNo('profile %1 kind', ProfileCode));
    end;

    // Same lookup as test 94325: an explicit row for the object, else the type's wildcard row (Object ID 0).
    local procedure FindRow(RoleId: Text; ObjectType: Option; ObjectId: Integer; var Perm: Record "Expanded Permission"): Boolean
    var
        AppId: Guid;
    begin
        Evaluate(AppId, BcmagAppIdTok);
        Perm.Reset();
        Perm.SetRange("App ID", AppId);
        Perm.SetRange("Role ID", CopyStr(RoleId, 1, MaxStrLen(Perm."Role ID")));
        Perm.SetRange("Object Type", ObjectType);
        Perm.SetRange("Object ID", ObjectId);
        if Perm.FindFirst() then
            exit(true);
        Perm.SetRange("Object ID", 0);
        exit(Perm.FindFirst());
    end;
}
