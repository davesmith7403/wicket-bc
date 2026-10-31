codeunit 94319 "Bcmag Capabilities Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    // The capabilities manifest is the machine-readable self-description agents auto-discover.
    // It must list every operation and carry the real bound-action URL template.

    var
        Op: Codeunit "Bcmag Op Capabilities";
        Helper: Codeunit "Bcmag Test Helper";
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure CapabilitiesListsAllOperationsAndUrlTemplate()
    var
        Data, Response, Value, Fail: JsonObject;
        Tok: JsonToken;
        Operations: JsonArray;
        Cost: Integer;
        UrlTemplate: Text;
    begin
        LibraryAssert.IsTrue(Op.Run(Data, Response, Fail, Cost), 'capabilities should succeed');
        Value := Helper.ValueObject(Response);

        LibraryAssert.IsTrue(Value.Get('operations', Tok), 'operations missing');
        Operations := Tok.AsArray();
        LibraryAssert.AreEqual(18, Operations.Count(), 'expected 18 operations (keep in step with the endpoint page)');

        LibraryAssert.IsTrue(Value.Get('urlTemplate', Tok), 'urlTemplate missing');
        UrlTemplate := Tok.AsValue().AsText();
        LibraryAssert.IsTrue(StrPos(UrlTemplate, 'Microsoft.NAV') > 0, 'urlTemplate must reference the bound-action namespace');
    end;

    [Test]
    procedure CapabilitiesReportsMaskingPosture()
    var
        Rule: Record "Bcmag Classification Rule";
        Profile: Record "Bcmag Mask Profile";
        PolicyDefaults: Codeunit "Bcmag Policy Defaults";
        FieldPolicyObj, Entry, PrincipalObj: JsonObject;
        Tok: JsonToken;
        Arr: JsonArray;
        FoundEuii, FoundPartial: Boolean;
        Scope: Option Classification,Field;
    begin
        // fieldPolicy carries the effective classification rules (EUII Masked out of the box), every
        // mask profile with its shape, whether the Unmask tier is honored, and what the CALLER's grants
        // do right now. The suite runs as SUPER, which holds the tier once it is enabled.
        Helper.ConfigureOpenMode(); // tier off
        Helper.ClearUserExceptions();
        Rule.DeleteAll();
        Profile.DeleteAll();
        PolicyDefaults.SeedFieldPolicyDefaults();

        FieldPolicyObj := FieldPolicyOf();
        LibraryAssert.IsFalse(FieldPolicyObj.Contains('exposedClassifications'), 'exposedClassifications is gone');
        LibraryAssert.IsTrue(FieldPolicyObj.Get('classifications', Tok), 'classifications missing');
        Arr := Tok.AsArray();
        LibraryAssert.AreEqual(7, Arr.Count(), 'one entry per classification');
        foreach Tok in Arr do begin
            Entry := Tok.AsObject();
            if Helper.TextField(Entry, 'name') = 'EndUserIdentifiableInformation' then begin
                FoundEuii := true;
                LibraryAssert.AreEqual('masked', Helper.TextField(Entry, 'access'), 'EUII is Masked by default');
                LibraryAssert.AreEqual('PARTIAL', Helper.TextField(Entry, 'maskProfile'), 'EUII profile');
            end;
        end;
        LibraryAssert.IsTrue(FoundEuii, 'EUII entry missing');

        LibraryAssert.IsTrue(FieldPolicyObj.Get('maskProfiles', Tok), 'maskProfiles missing');
        Arr := Tok.AsArray();
        LibraryAssert.AreEqual(5, Arr.Count(), 'every seeded mask profile is listed');
        foreach Tok in Arr do begin
            Entry := Tok.AsObject();
            if Helper.TextField(Entry, 'code') = 'PARTIAL' then begin
                FoundPartial := true;
                LibraryAssert.AreEqual('keepLast', Helper.TextField(Entry, 'kind'), 'PARTIAL kind');
                LibraryAssert.AreEqual(0, IntMember(Entry, 'keepFirst'), 'PARTIAL keepFirst');
                LibraryAssert.AreEqual(2, IntMember(Entry, 'keepLast'), 'PARTIAL keepLast');
                LibraryAssert.AreEqual(4, IntMember(Entry, 'minHidden'), 'PARTIAL minHidden');
                LibraryAssert.IsFalse(BoolMember(Entry, 'preserveLength'), 'PARTIAL preserveLength');
            end;
        end;
        LibraryAssert.IsTrue(FoundPartial, 'PARTIAL profile missing');

        LibraryAssert.IsFalse(BoolMember(FieldPolicyObj, 'unmaskTierEnabled'), 'the baseline keeps the tier off');
        LibraryAssert.IsTrue(FieldPolicyObj.Get('principal', Tok), 'principal missing');
        PrincipalObj := Tok.AsObject();
        LibraryAssert.IsFalse(BoolMember(PrincipalObj, 'unmaskGranted'), 'a disabled tier is never granted');
        LibraryAssert.AreEqual(0, IntMember(PrincipalObj, 'activeExceptions'), 'no exceptions yet');

        // An active exception for the caller, and the tier switched on.
        Helper.AddUserException(Scope::Field, "Bcmag Data Class"::CustomerContent, Database::"Bcmag Setup", 1, "Bcmag Read Access"::Clear, '', 0DT);
        Helper.SetUnmaskTierEnabled(true);
        FieldPolicyObj := FieldPolicyOf();
        LibraryAssert.IsTrue(BoolMember(FieldPolicyObj, 'unmaskTierEnabled'), 'unmaskTierEnabled follows Setup');
        FieldPolicyObj.Get('principal', Tok);
        PrincipalObj := Tok.AsObject();
        LibraryAssert.IsTrue(BoolMember(PrincipalObj, 'unmaskGranted'), 'SUPER holds the enabled tier');
        LibraryAssert.AreEqual(1, IntMember(PrincipalObj, 'activeExceptions'), 'the active exception is counted');

        Helper.SetUnmaskTierEnabled(false);
        Helper.ClearUserExceptions();
    end;

    [Test]
    procedure CapabilitiesListsDisabledActionsWithTheirArgsSchema()
    var
        Catalog: Record "Bcmag Action Catalog";
        Data, Response, Value, Fail, Entry, Schema : JsonObject;
        Tok: JsonToken;
        Cost: Integer;
    begin
        // Every enrolled verb is listed with enabled = Allow Run, so "no companion" (empty) and "enrolled
        // but disabled" read differently. argsSchema comes from the catalog's Args Schema when it parses
        // as a JSON object and is omitted otherwise (a broken schema must not break capabilities).
        Helper.ConfigureOpenMode();
        Helper.EnrolAction('bcmag-cap-on', Codeunit::"Bcmag Echo Args Wrapper", false);
        Catalog.Get('bcmag-cap-on');
        Catalog.SetArgsSchema('{"type":"object","required":["no"]}');
        Catalog.Modify();
        Helper.EnrolAction('bcmag-cap-off', Codeunit::"Bcmag Echo Args Wrapper", false);
        Catalog.Get('bcmag-cap-off');
        Catalog."Allow Run" := false;
        Catalog."Is Mutating" := false;
        Catalog.SetArgsSchema('not json');
        Catalog.Modify();

        LibraryAssert.IsTrue(Op.Run(Data, Response, Fail, Cost), 'capabilities should succeed');
        Value := Helper.ValueObject(Response);

        LibraryAssert.IsTrue(FindAction(Value, 'bcmag-cap-on', Entry), 'the enabled verb is listed');
        LibraryAssert.IsTrue(BoolMember(Entry, 'enabled'), 'enabled = Allow Run');
        LibraryAssert.IsTrue(Entry.Get('argsSchema', Tok), 'argsSchema is emitted');
        LibraryAssert.IsTrue(Tok.IsObject(), 'argsSchema is a JSON object, not a string');
        Schema := Tok.AsObject();
        LibraryAssert.AreEqual('object', Helper.TextField(Schema, 'type'), 'the stored schema comes back as stored');

        LibraryAssert.IsTrue(FindAction(Value, 'bcmag-cap-off', Entry), 'a disabled verb is listed too');
        LibraryAssert.IsFalse(BoolMember(Entry, 'enabled'), 'enabled = false');
        LibraryAssert.IsFalse(BoolMember(Entry, 'mutating'), 'mutating follows Is Mutating');
        LibraryAssert.IsFalse(Entry.Contains('argsSchema'), 'a schema that is not a JSON object is omitted');

        Catalog.Get('bcmag-cap-on');
        Catalog.Delete();
        Catalog.Get('bcmag-cap-off');
        Catalog.Delete();
    end;

    local procedure FindAction(Value: JsonObject; ActionCode: Text; var Entry: JsonObject): Boolean
    var
        Tok, Item : JsonToken;
    begin
        if not Value.Get('actions', Tok) then
            exit(false);
        foreach Item in Tok.AsArray() do
            if Helper.TextField(Item.AsObject(), 'action') = ActionCode then begin
                Entry := Item.AsObject();
                exit(true);
            end;
        exit(false);
    end;

    local procedure FieldPolicyOf(): JsonObject
    var
        Data, Response, Fail, Value: JsonObject;
        Tok: JsonToken;
        Cost: Integer;
    begin
        LibraryAssert.IsTrue(Op.Run(Data, Response, Fail, Cost), 'capabilities should succeed');
        Value := Helper.ValueObject(Response);
        LibraryAssert.IsTrue(Value.Get('fieldPolicy', Tok), 'fieldPolicy missing');
        exit(Tok.AsObject());
    end;

    local procedure IntMember(Obj: JsonObject; Name: Text): Integer
    var
        Tok: JsonToken;
    begin
        LibraryAssert.IsTrue(Obj.Get(Name, Tok), StrSubstNo('"%1" missing', Name));
        exit(Tok.AsValue().AsInteger());
    end;

    local procedure BoolMember(Obj: JsonObject; Name: Text): Boolean
    var
        Tok: JsonToken;
    begin
        LibraryAssert.IsTrue(Obj.Get(Name, Tok), StrSubstNo('"%1" missing', Name));
        exit(Tok.AsValue().AsBoolean());
    end;
}
