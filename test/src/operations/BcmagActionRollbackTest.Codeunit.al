codeunit 94343 "Bcmag Action Rollback Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    // The forced-rollback boundary of the `action` operation: a preview, or a verb enrolled with Is
    // Mutating = false, runs its wrapper so that nothing it writes persists — even a wrapper that commits
    // — while its result still reaches the caller. Because nothing can take effect, exactly those calls
    // pass Read-Only Mode and the key requirement; a mutating verb is still refused and still commits.

    var
        Dispatcher: Codeunit "Bcmag Rpc Dispatcher";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";
        ProbeTok: Label 'bcmag-test-probe', Locked = true;

    [Test]
    procedure NonMutatingVerbReturnsItsResultAndPersistsNothing()
    var
        Response: JsonObject;
        Marker: Text;
        Status: Integer;
    begin
        Setup(false, false);
        Marker := NewMarker();
        Response := RunProbe(Marker, true, false, false, '', Status);
        LibraryAssert.AreEqual(200, Status, 'a non-mutating verb runs: ' + Describe(Response));
        LibraryAssert.AreEqual(Marker, Helper.TextField(Helper.ValueObject(Response), 'wrote'), 'the wrapper result reaches the caller');
        LibraryAssert.AreEqual(0, Rows(Marker), 'its write (and its Commit) did not persist');
    end;

    [Test]
    procedure PreviewOfAMutatingVerbPersistsNothing()
    var
        Response: JsonObject;
        Marker: Text;
        Status: Integer;
    begin
        Setup(true, true);
        Marker := NewMarker();
        Response := RunProbe(Marker, true, false, true, '', Status);
        LibraryAssert.AreEqual(200, Status, 'the preview runs: ' + Describe(Response));
        LibraryAssert.AreEqual(0, Rows(Marker), 'a preview never persists, even when the wrapper commits');
    end;

    [Test]
    procedure MutatingVerbStillCommits()
    var
        Response: JsonObject;
        Marker: Text;
        Status: Integer;
    begin
        Setup(true, true);
        Marker := NewMarker();
        Response := RunProbe(Marker, false, false, false, Helper.NewIdemKey(), Status);
        LibraryAssert.AreEqual(200, Status, 'the real run: ' + Describe(Response));
        LibraryAssert.AreEqual(1, Rows(Marker), 'outside a preview a mutating verb commits as before');
    end;

    [Test]
    procedure FailingWrapperInTheRollbackReportsItsOwnError()
    var
        Response: JsonObject;
        Marker: Text;
        Status: Integer;
    begin
        Setup(false, false);
        Marker := NewMarker();
        Response := RunProbe(Marker, false, true, false, '', Status);
        LibraryAssert.AreEqual(422, Status, 'a wrapper error is a 422: ' + Describe(Response));
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Response), 'action-failed') > 0, 'action-failed');
        LibraryAssert.IsTrue(StrPos(Helper.DetailOf(Response), 'probe failed after writing') > 0, 'the wrapper''s message, not the rollback sentinel: ' + Describe(Response));
        LibraryAssert.AreEqual(0, Rows(Marker), 'nothing persisted');
    end;

    [Test]
    procedure NonMutatingVerbCannotCommitThroughANestedCodeunitRun()
    var
        Args, Data, Body, Response : JsonObject;
        Marker: Text;
        Status: Integer;
    begin
        // CommitBehavior covers explicit commits only; a nested Codeunit.Run whose return value is used
        // commits on success. The boundary opens a write transaction first, so Business Central refuses
        // that nested run instead: the verb fails (or reports the inner failure) and nothing persists.
        Helper.ConfigureOpenMode();
        Helper.EnrolAction(ProbeTok, Codeunit::"Bcmag Nested Run Probe", false);
        SetMutating(false);
        Marker := NewMarker();
        Args.Add('marker', Marker);
        Data.Add('action', ProbeTok);
        Data.Add('args', Args);
        Body := Helper.Envelope(Data);
        Helper.CommitFixtures();
        Response := Dispatcher.RunEx('action', Body, '', Status);
        LibraryAssert.AreEqual(0, Rows(Marker), 'the nested run did not commit: ' + Describe(Response));
        if Status = 200 then
            LibraryAssert.IsFalse(Helper.ValueObject(Response).Contains('innerRan'), 'the nested run was refused, not completed: ' + Describe(Response));
    end;

    [Test]
    procedure ReadOnlyModeLetsOnlyRollbackActionsThrough()
    var
        Response: JsonObject;
        Status: Integer;
    begin
        Setup(false, true);
        Helper.SetReadOnlyMode(true);
        Response := RunProbe(NewMarker(), false, false, false, '', Status);
        LibraryAssert.AreEqual(200, Status, 'a non-mutating verb runs on a read-only endpoint: ' + Describe(Response));

        SetMutating(true);
        Response := RunProbe(NewMarker(), false, false, true, '', Status);
        LibraryAssert.AreEqual(200, Status, 'a preview runs on a read-only endpoint: ' + Describe(Response));
        Response := RunProbe(NewMarker(), false, false, false, Helper.NewIdemKey(), Status);
        LibraryAssert.AreEqual(403, Status, 'a mutating call is still refused: ' + Describe(Response));
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Response), 'read-only') > 0, 'with the read-only problem');
        Helper.SetReadOnlyMode(false);
    end;

    [Test]
    procedure KeyRequirementSkipsRollbackActions()
    var
        Response: JsonObject;
        Status: Integer;
    begin
        Setup(false, true);
        Helper.SetRequireKeyForActions(true);
        Response := RunProbe(NewMarker(), false, false, false, '', Status);
        LibraryAssert.AreEqual(200, Status, 'a non-mutating verb needs no key: ' + Describe(Response));
        SetMutating(true);
        Response := RunProbe(NewMarker(), false, false, true, '', Status);
        LibraryAssert.AreEqual(200, Status, 'a preview needs no key: ' + Describe(Response));
        Response := RunProbe(NewMarker(), false, false, false, '', Status);
        LibraryAssert.AreEqual(400, Status, 'a mutating call without a key is refused: ' + Describe(Response));
        LibraryAssert.IsTrue(StrPos(Helper.TypeOf(Response), 'idempotency-key-required') > 0, 'idempotency-key-required');
        Helper.SetRequireKeyForActions(false);
    end;

    local procedure Setup(IsMutating: Boolean; PreviewSupported: Boolean)
    begin
        Helper.ConfigureOpenMode();
        Helper.EnrolAction(ProbeTok, Codeunit::"Bcmag Rollback Probe Wrapper", PreviewSupported);
        SetMutating(IsMutating);
    end;

    local procedure SetMutating(IsMutating: Boolean)
    var
        Catalog: Record "Bcmag Action Catalog";
    begin
        Catalog.Get(ProbeTok);
        Catalog."Is Mutating" := IsMutating;
        Catalog.Modify();
    end;

    local procedure RunProbe(Marker: Text; DoCommit: Boolean; FailAfterWrite: Boolean; Preview: Boolean; IdemKey: Text; var Status: Integer): JsonObject
    var
        Args, Data, Body : JsonObject;
    begin
        Args.Add('marker', Marker);
        Args.Add('commit', DoCommit);
        Args.Add('failAfterWrite', FailAfterWrite);
        Data.Add('action', ProbeTok);
        Data.Add('args', Args);
        if Preview then
            Data.Add('preview', true);
        if IdemKey <> '' then
            Body := Helper.EnvelopeWithKey(Data, IdemKey)
        else
            Body := Helper.Envelope(Data);
        Helper.CommitFixtures();
        exit(Dispatcher.RunEx('action', Body, '', Status));
    end;

    local procedure Rows(Marker: Text): Integer
    var
        ActivityLog: Record "Activity Log";
    begin
        ActivityLog.SetRange(Description, CopyStr(Marker, 1, MaxStrLen(ActivityLog.Description)));
        exit(ActivityLog.Count());
    end;

    local procedure NewMarker(): Text
    begin
        exit('BCMAG-RB-' + DelChr(LowerCase(Format(CreateGuid())), '<>', '{}'));
    end;

    local procedure Describe(Obj: JsonObject) Json: Text
    begin
        Obj.WriteTo(Json);
    end;
}
