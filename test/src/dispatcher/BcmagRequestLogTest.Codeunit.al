codeunit 94339 "Bcmag Request Log Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    // What the Operation Log records about a request, end to end through the dispatcher: the table and
    // target always, the request's shape (Request Details) while Setup "Log Request Details" is on, and
    // never the values a write carried.

    var
        Dispatcher: Codeunit "Bcmag Rpc Dispatcher";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure QueryLogsTableAndRequestDetails()
    var
        Log: Record "Bcmag Operation Log";
        Data: JsonObject;
        Select: JsonArray;
        Body: JsonObject;
    begin
        Helper.ConfigureOpenMode();
        SetLogRequestDetails(true);
        Data.Add('tableId', Database::Customer);
        Data.Add('filter', 'No. eq ''LOG-PROBE''');
        Select.Add('No.');
        Select.Add('Name');
        Data.Add('select', Select);
        Data.Add('top', 5);
        Body := Helper.Envelope(Data);
        Send('query', Body);

        FindLog(Body, Log);
        LibraryAssert.AreEqual(Database::Customer, Log."Table Id", 'the table is always recorded');
        LibraryAssert.IsTrue(StrPos(Log."Request Details", 'No. eq ''LOG-PROBE''') > 0, 'the filter is recorded: ' + Log."Request Details");
        LibraryAssert.IsTrue(StrPos(Log."Request Details", '"select"') > 0, 'the select is recorded: ' + Log."Request Details");
        LibraryAssert.IsTrue(StrPos(Log."Request Details", '"top":5') > 0, 'top is recorded: ' + Log."Request Details");
    end;

    [Test]
    procedure SwitchedOffKeepsTheTableButNoDetails()
    var
        Log: Record "Bcmag Operation Log";
        Data: JsonObject;
        Body: JsonObject;
    begin
        Helper.ConfigureOpenMode();
        SetLogRequestDetails(false);
        Data.Add('tableId', Database::Customer);
        Data.Add('filter', 'No. eq ''LOG-PROBE''');
        Body := Helper.Envelope(Data);
        Send('query', Body);

        FindLog(Body, Log);
        LibraryAssert.AreEqual(Database::Customer, Log."Table Id", 'the table is recorded with details off too');
        LibraryAssert.AreEqual('', Log."Request Details", 'no request details while the switch is off');
        SetLogRequestDetails(true);
    end;

    [Test]
    procedure WriteLogsFieldNamesNeverValues()
    var
        Log: Record "Bcmag Operation Log";
        Data, Values: JsonObject;
        Body: JsonObject;
        Marker: Text;
    begin
        Helper.ConfigureOpenMode();
        SetLogRequestDetails(true);
        Marker := 'LOG-SECRET-' + DelChr(LowerCase(Format(CreateGuid())), '<>', '{}');
        Values.Add('Description', Marker);
        Data.Add('tableId', Database::"Activity Log");
        Data.Add('values', Values);
        Data.Add('init', false);
        Body := Helper.Envelope(Data);
        Send('insert', Body);

        FindLog(Body, Log);
        LibraryAssert.AreEqual(Database::"Activity Log", Log."Table Id", 'the written table is recorded');
        LibraryAssert.IsTrue(StrPos(Log."Request Details", '"values":["Description"]') > 0, 'the field name is recorded: ' + Log."Request Details");
        LibraryAssert.AreEqual(0, StrPos(Log."Request Details", Marker), 'the written value must never be recorded');
    end;

    [Test]
    procedure ActionLogsItsCodeAsTarget()
    var
        Log: Record "Bcmag Operation Log";
        Data: JsonObject;
        Body: JsonObject;
    begin
        // Recorded even when the action is refused: the audit row says what was attempted.
        Helper.ConfigureOpenMode();
        Data.Add('action', 'wicket-log-probe-action');
        Body := Helper.EnvelopeWithKey(Data, Helper.NewIdemKey());
        Send('action', Body);

        FindLog(Body, Log);
        LibraryAssert.AreEqual('wicket-log-probe-action', Log.Target, 'the action code is the target');
        LibraryAssert.AreEqual(0, Log."Table Id", 'an action names no table');
    end;

    [Test]
    procedure ReaperPurgesOperationLogRowsPastRetention()
    var
        Setup: Record "Bcmag Setup";
        Log: Record "Bcmag Operation Log";
        Reaper: Codeunit "Bcmag Async Reaper";
        OldEntry, RecentEntry: BigInteger;
    begin
        // Retention holds without a Job Queue Entry: the reaper, armed at install, runs the purge.
        Setup.GetSingleton();
        Setup."Operation Log Retention Days" := 30;
        Setup.Modify();
        OldEntry := InsertLogRow(CreateDateTime(Today() - 40, 0T));
        RecentEntry := InsertLogRow(CurrentDateTime());
        Helper.CommitFixtures();

        Reaper.RunOnce();

        LibraryAssert.IsFalse(Log.Get(OldEntry), 'a row older than the retention must be purged by the reaper');
        LibraryAssert.IsTrue(Log.Get(RecentEntry), 'a recent row must stay');
    end;

    [Test]
    procedure ZeroRetentionKeepsEveryRow()
    var
        Setup: Record "Bcmag Setup";
        Log: Record "Bcmag Operation Log";
        Reaper: Codeunit "Bcmag Async Reaper";
        OldEntry: BigInteger;
    begin
        Setup.GetSingleton();
        Setup."Operation Log Retention Days" := 0;
        Setup.Modify();
        OldEntry := InsertLogRow(CreateDateTime(Today() - 400, 0T));
        Helper.CommitFixtures();

        Reaper.RunOnce();

        LibraryAssert.IsTrue(Log.Get(OldEntry), 'retention 0 means keep forever');
        Setup.Get('');
        Setup."Operation Log Retention Days" := 30;
        Setup.Modify();
        Log.Get(OldEntry);
        Log.Delete();
        Helper.CommitFixtures();
    end;

    local procedure InsertLogRow(StartedAt: DateTime): BigInteger
    var
        Log: Record "Bcmag Operation Log";
    begin
        Log.Init();
        Log."Request Id" := CopyStr('retention-' + DelChr(LowerCase(Format(CreateGuid())), '<>', '{}'), 1, MaxStrLen(Log."Request Id"));
        Log.Operation := 'query';
        Log."Started At" := StartedAt;
        Log."Ended At" := StartedAt;
        Log.Insert();
        exit(Log."Entry No.");
    end;

    local procedure Send(Operation: Text; Body: JsonObject)
    var
        Status: Integer;
    begin
        Helper.CommitFixtures();
        Dispatcher.RunEx(Operation, Body, '', Status);
    end;

    local procedure FindLog(Body: JsonObject; var Log: Record "Bcmag Operation Log")
    var
        Tok: JsonToken;
    begin
        Body.Get('id', Tok);
        Log.SetRange("Request Id", Tok.AsValue().AsText());
        LibraryAssert.IsTrue(Log.FindLast(), 'the request must have an Operation Log row');
    end;

    local procedure SetLogRequestDetails(Value: Boolean)
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.GetSingleton();
        Setup."Log Request Details" := Value;
        Setup.Modify();
    end;
}
