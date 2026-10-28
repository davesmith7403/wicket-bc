codeunit 94337 "Bcmag Setup Preset Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    // The Setup Card presets (Bcmag Setup.ApplyPreset / CurrentPreset), end to end through
    // "Bcmag Rpc Dispatcher".RunEx: what each preset makes reachable, what it refuses, and that the
    // field policy is left alone by every preset except Developer Sandbox.

    var
        Dispatcher: Codeunit "Bcmag Rpc Dispatcher";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure SimpleReadOnlyReadsUnlistedTablesRefusesWritesKeepsFieldPolicy()
    var
        Setup: Record "Bcmag Setup";
        Response: JsonObject;
        Status: Integer;
    begin
        StartAllowlistedByClassification();

        Setup.ApplyPreset("Bcmag Setup Preset"::SimpleReadOnly);
        Helper.CommitFixtures();

        Setup.Get('');
        LibraryAssert.AreEqual(Setup.Mode::Open, Setup.Mode, 'Simple Read-Only must switch to Open mode');
        LibraryAssert.IsTrue(Setup."Read-Only Mode", 'Simple Read-Only must turn on Read-Only Mode');
        LibraryAssert.IsFalse(Setup."Allow Invoke In Open Mode", 'Simple Read-Only must clear the invoke switch');
        LibraryAssert.AreEqual(Setup."Field Policy Mode"::ByClassification, Setup."Field Policy Mode", 'the field policy must not change');

        Response := Dispatcher.RunEx('query', Helper.Envelope(QueryData()), '', Status);
        LibraryAssert.AreEqual(200, Status, 'an unlisted table must be readable');

        // Each call writes its Operation Log row; Codeunit.Run needs that committed before the next.
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('insert', Helper.Envelope(InsertData()), '', Status);
        AssertRefused(Response, Status, 'read-only', 'an insert under Simple Read-Only');

        RestoreBaseline();
    end;

    [Test]
    procedure ReadOnlySelectedTablesReadsOnlyAllowedTablesRefusesWrites()
    var
        Setup: Record "Bcmag Setup";
        Response: JsonObject;
        Status: Integer;
    begin
        Helper.ConfigureOpenMode();
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::ByClassification);
        Helper.UnexposeTable(Database::"Activity Log");

        Setup.ApplyPreset("Bcmag Setup Preset"::ReadOnlySelectedTables);
        Helper.CommitFixtures();

        Setup.Get('');
        LibraryAssert.AreEqual(Setup.Mode::Allowlisted, Setup.Mode, 'Selected Tables must switch to Allowlisted mode');
        LibraryAssert.IsTrue(Setup."Read-Only Mode", 'Selected Tables must turn on Read-Only Mode');
        LibraryAssert.AreEqual(Setup."Field Policy Mode"::ByClassification, Setup."Field Policy Mode", 'the field policy must not change');

        Response := Dispatcher.RunEx('query', Helper.Envelope(QueryData()), '', Status);
        AssertRefused(Response, Status, 'not-exposed', 'a query on an unlisted table');

        Helper.ExposeTable(Database::"Activity Log", true, true, false, false);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('query', Helper.Envelope(QueryData()), '', Status);
        LibraryAssert.AreEqual(200, Status, 'an allowed table must be readable');

        // Even an exposure row that allows insert cannot reopen writes: Read-Only Mode comes first.
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('insert', Helper.Envelope(InsertData()), '', Status);
        AssertRefused(Response, Status, 'read-only', 'an insert under Read-Only (Selected Tables)');

        Helper.UnexposeTable(Database::"Activity Log");
        RestoreBaseline();
    end;

    [Test]
    procedure ReadAndActionsReadsUnlistedTablesKeepsInvokeOffAndFieldPolicy()
    var
        Setup: Record "Bcmag Setup";
        Response: JsonObject;
        Status: Integer;
    begin
        StartAllowlistedByClassification();
        Helper.SetReadOnlyMode(true);

        Setup.ApplyPreset("Bcmag Setup Preset"::ReadAndActions);
        Helper.CommitFixtures();

        Setup.Get('');
        LibraryAssert.AreEqual(Setup.Mode::Open, Setup.Mode, 'Read + Business Actions must switch to Open mode');
        LibraryAssert.IsFalse(Setup."Read-Only Mode", 'Read + Business Actions must turn Read-Only Mode off so actions can run');
        LibraryAssert.IsFalse(Setup."Allow Invoke In Open Mode", 'Read + Business Actions must keep invoke deny-by-default');
        LibraryAssert.AreEqual(Setup."Field Policy Mode"::ByClassification, Setup."Field Policy Mode", 'the field policy must not change');

        Response := Dispatcher.RunEx('query', Helper.Envelope(QueryData()), '', Status);
        LibraryAssert.AreEqual(200, Status, 'an unlisted table must be readable');

        RestoreBaseline();
    end;

    [Test]
    procedure DeveloperSandboxOpensEverythingOnlyOutsideProduction()
    var
        Setup: Record "Bcmag Setup";
        EnvironmentInformation: Codeunit "Environment Information";
    begin
        StartAllowlistedByClassification();
        Helper.SetReadOnlyMode(true);
        Helper.CommitFixtures();

        if EnvironmentInformation.IsProduction() then begin
            asserterror Setup.ApplyPreset("Bcmag Setup Preset"::DeveloperSandbox);
            LibraryAssert.ExpectedError('can only be applied in a sandbox environment');
            Setup.Get('');
            LibraryAssert.AreEqual(Setup.Mode::Allowlisted, Setup.Mode, 'a refused preset must leave the settings alone');
            LibraryAssert.IsTrue(Setup."Read-Only Mode", 'a refused preset must leave Read-Only Mode on');
        end else begin
            Setup.ApplyPreset("Bcmag Setup Preset"::DeveloperSandbox);
            Setup.Get('');
            LibraryAssert.AreEqual(Setup.Mode::Open, Setup.Mode, 'Developer Sandbox must switch to Open mode');
            LibraryAssert.IsFalse(Setup."Read-Only Mode", 'Developer Sandbox must turn Read-Only Mode off');
            LibraryAssert.IsTrue(Setup."Allow Invoke In Open Mode", 'Developer Sandbox must allow invoke');
            LibraryAssert.AreEqual(Setup."Field Policy Mode"::AllFields, Setup."Field Policy Mode", 'Developer Sandbox must show every field');
        end;

        RestoreBaseline();
    end;

    [Test]
    procedure CurrentPresetNamesEveryPresetAndCustom()
    var
        Setup: Record "Bcmag Setup";
    begin
        // The fresh-install posture (Allowlisted, writable) matches no preset.
        Helper.ConfigureAllowlistedMode();
        Setup.Get('');
        LibraryAssert.AreEqual("Bcmag Setup Preset"::Custom, Setup.CurrentPreset(), 'Allowlisted and writable is Custom');

        AssertRoundTrip("Bcmag Setup Preset"::SimpleReadOnly);
        AssertRoundTrip("Bcmag Setup Preset"::ReadOnlySelectedTables);
        AssertRoundTrip("Bcmag Setup Preset"::ReadAndActions);

        // Open, writable, invoke on but the field policy still restrictive: not Developer Sandbox.
        Setup.Get('');
        Setup.Mode := Setup.Mode::Open;
        Setup."Read-Only Mode" := false;
        Setup."Allow Invoke In Open Mode" := true;
        Setup."Field Policy Mode" := Setup."Field Policy Mode"::ByClassification;
        Setup.Modify(true);
        LibraryAssert.AreEqual("Bcmag Setup Preset"::Custom, Setup.CurrentPreset(), 'invoke on under a restrictive field policy is Custom');

        Setup."Field Policy Mode" := Setup."Field Policy Mode"::AllFields;
        Setup.Modify(true);
        LibraryAssert.AreEqual("Bcmag Setup Preset"::DeveloperSandbox, Setup.CurrentPreset(), 'Open, writable, invoke and AllFields is Developer Sandbox');

        RestoreBaseline();
    end;

    local procedure AssertRoundTrip(Preset: Enum "Bcmag Setup Preset")
    var
        Setup: Record "Bcmag Setup";
        RoundTripMsg: Label 'CurrentPreset must report %1 after applying it', Locked = true;
    begin
        Setup.ApplyPreset(Preset);
        Setup.Get('');
        LibraryAssert.AreEqual(Preset, Setup.CurrentPreset(), StrSubstNo(RoundTripMsg, Preset));
    end;

    local procedure StartAllowlistedByClassification()
    begin
        Helper.ConfigureAllowlistedMode();
        Helper.UnexposeTable(Database::"Activity Log");
        Helper.SetFieldPolicyMode("Bcmag Field Policy Mode"::ByClassification);
    end;

    local procedure RestoreBaseline()
    begin
        Helper.ConfigureOpenMode();
        Helper.CommitFixtures();
    end;

    local procedure QueryData() Data: JsonObject
    begin
        Data.Add('tableId', Database::"Activity Log");
        Data.Add('top', 1);
    end;

    local procedure InsertData() Data: JsonObject
    var
        Values: JsonObject;
    begin
        Values.Add('Description', 'BCMAG-PRESET-' + DelChr(LowerCase(Format(CreateGuid())), '<>', '{}'));
        Data.Add('tableId', Database::"Activity Log");
        Data.Add('values', Values);
        Data.Add('init', false);
    end;

    local procedure AssertRefused(Response: JsonObject; Status: Integer; ExpectedType: Text; Context: Text)
    begin
        LibraryAssert.AreEqual(403, Status, Context + ' must be refused 403');
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Response), ExpectedType) > 0, Context + ': expected ' + ExpectedType + ', got ' + Helper.TypeOf(Response));
    end;
}
