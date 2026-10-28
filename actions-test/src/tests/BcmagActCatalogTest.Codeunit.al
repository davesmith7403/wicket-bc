codeunit 94355 "Bcmag Act Catalog Test"
{
    // The companion's enrolment as an agent sees it: every verb carries its metadata and args schema in
    // capabilities.actions, and an upgrade brings that metadata up to date on rows a tenant enrolled
    // earlier without ever touching the administrator's Allow Run.
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibraryAssert: Codeunit "Library Assert";
        Helper: Codeunit "Bcmag Act Test Helper";

    [Test]
    procedure EveryCompanionVerbAdvertisesItsArgsSchema()
    var
        Catalog: Record "Bcmag Action Catalog";
        Install: Codeunit "Bcmag Act Install";
        Value, Entry : JsonObject;
        Tok: JsonToken;
        Verbs: List of [Text];
        Verb: Text;
    begin
        Helper.Initialize();
        Install.RefreshAll();
        Value := Capabilities();
        Verbs := CompanionVerbs();
        foreach Verb in Verbs do begin
            LibraryAssert.IsTrue(FindAction(Value, Verb, Entry), Verb + ' is listed: ' + Describe(Value));
            LibraryAssert.IsTrue(Entry.Get('argsSchema', Tok), Verb + ' carries an argsSchema (the stored text parses): ' + Describe(Entry));
            LibraryAssert.IsTrue(Tok.IsObject(), Verb + ' argsSchema is an object');
            LibraryAssert.AreNotEqual('', Helper.Txt(Entry, 'category'), Verb + ' has a category');
            Catalog.Get(Verb);
            LibraryAssert.AreEqual(Catalog."Allow Run", Helper.Bool(Entry, 'enabled'), Verb + ' enabled = Allow Run');
        end;
    end;

    [Test]
    procedure UpgradeRefreshesMetadataButNeverAllowRun()
    var
        Catalog: Record "Bcmag Action Catalog";
        Install: Codeunit "Bcmag Act Install";
    begin
        // A row as an older companion left it: stale category and flags, no args schema. Allow Run is the
        // administrator's and must come out of the refresh exactly as it went in, both ways.
        Helper.Initialize();
        Catalog.Get('post-sales');
        Catalog.Category := 'stale';
        Catalog."Is Mutating" := false;
        Catalog.SetArgsSchema('');
        Catalog."Allow Run" := true;
        Catalog.Modify();
        Catalog.Get('post-purchase');
        Catalog.Category := 'stale';
        Catalog."Allow Run" := false;
        Catalog.Modify();

        Install.RefreshAll();

        Catalog.Get('post-sales');
        LibraryAssert.AreEqual('post', Catalog.Category, 'category refreshed');
        LibraryAssert.IsTrue(Catalog."Is Mutating", 'Is Mutating refreshed');
        LibraryAssert.AreNotEqual('', Catalog.GetArgsSchema(), 'args schema refreshed');
        LibraryAssert.IsTrue(Catalog."Allow Run", 'an enabled verb stays enabled');
        Catalog.Get('post-purchase');
        LibraryAssert.AreEqual('post', Catalog.Category, 'category refreshed on a disabled row');
        LibraryAssert.IsFalse(Catalog."Allow Run", 'a disabled verb stays disabled');
    end;

    [Test]
    procedure UpgradeNeverLoosensIsMutating()
    var
        Catalog: Record "Bcmag Action Catalog";
        Install: Codeunit "Bcmag Act Install";
    begin
        // An administrator keeps document-pdf off read-only endpoints by marking it mutating; the next
        // upgrade must not quietly open it again.
        Helper.Initialize();
        Catalog.Get('document-pdf');
        LibraryAssert.IsFalse(Catalog."Is Mutating", 'the companion enrols document-pdf non-mutating');
        Catalog."Is Mutating" := true;
        Catalog.Modify();

        Install.RefreshAll();

        Catalog.Get('document-pdf');
        LibraryAssert.IsTrue(Catalog."Is Mutating", 'the administrator''s stricter setting survives the upgrade');
        // Isolation is per codeunit: put the shipped value back for the tests that follow.
        Catalog."Is Mutating" := false;
        Catalog.Modify();
    end;

    [Test]
    procedure InstallEnrolsMissingVerbsDisabled()
    var
        Catalog: Record "Bcmag Action Catalog";
        Install: Codeunit "Bcmag Act Install";
        Value, Entry : JsonObject;
    begin
        Helper.Initialize();
        Catalog.Get('post-item-journal');
        Catalog.Delete();

        Install.EnrolAll();

        LibraryAssert.IsTrue(Catalog.Get('post-item-journal'), 'the missing verb is enrolled again');
        LibraryAssert.IsFalse(Catalog."Allow Run", 'a newly enrolled verb starts disabled');
        Value := Capabilities();
        LibraryAssert.IsTrue(FindAction(Value, 'post-item-journal', Entry), 'a disabled verb is still listed');
        LibraryAssert.IsFalse(Helper.Bool(Entry, 'enabled'), 'listed as enabled: false');
    end;

    local procedure CompanionVerbs() Verbs: List of [Text]
    begin
        Verbs.Add('post-sales');
        Verbs.Add('post-purchase');
        Verbs.Add('post-gen-journal');
        Verbs.Add('post-item-journal');
        Verbs.Add('release-sales');
        Verbs.Add('reopen-sales');
        Verbs.Add('release-purchase');
        Verbs.Add('reopen-purchase');
        Verbs.Add('make-order-from-quote');
        Verbs.Add('make-invoice-from-quote');
        Verbs.Add('make-purchase-order-from-quote');
        Verbs.Add('document-pdf');
        Verbs.Add('item-availability');
    end;

    local procedure Capabilities() Value: JsonObject
    var
        Op: Codeunit "Bcmag Op Capabilities";
        Data, Response, Fail : JsonObject;
        Cost: Integer;
    begin
        LibraryAssert.IsTrue(Op.Run(Data, Response, Fail, Cost), 'capabilities should succeed');
        Value := Helper.ValueOf(Response);
    end;

    local procedure FindAction(Value: JsonObject; ActionCode: Text; var Entry: JsonObject): Boolean
    var
        Tok, Item : JsonToken;
    begin
        if not Value.Get('actions', Tok) then
            exit(false);
        foreach Item in Tok.AsArray() do
            if Helper.Txt(Item.AsObject(), 'action') = ActionCode then begin
                Entry := Item.AsObject();
                exit(true);
            end;
        exit(false);
    end;

    local procedure Describe(Obj: JsonObject) Json: Text
    begin
        Obj.WriteTo(Json);
    end;
}
