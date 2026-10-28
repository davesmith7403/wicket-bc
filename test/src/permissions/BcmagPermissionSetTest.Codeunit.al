codeunit 94325 "Bcmag Permission Set Test"
{
    Subtype = Test;
    TestPermissions = Disabled;

    // Pins the shape of the shipped permission sets by reading the platform's "Expanded Permission"
    // virtual table, which resolves IncludedPermissionSets into the effective per-object grants
    // (the same data the client's "View all permissions" action shows). The suite cannot run an
    // operation AS a restricted principal (that needs the Base App test libraries this System-App-only
    // test app does not depend on), so these tests assert the composition itself: the read role has
    // no Execute on the write/invoke handlers, nothing below Admin can delete, the wildcard sets grant
    // what their names promise and nothing more, the legacy aliases equal their successors, and every
    // Wicket object is covered by the top set (so a new codeunit cannot silently ship ungranted).

    var
        LibraryAssert: Codeunit "Library Assert";
        BcmagAppIdTok: Label '4057cf1f-1b34-409a-a570-c6fdf625c434', Locked = true;

    [Test]
    procedure ReadRoleExecutesReadPlaneOnly()
    begin
        // Reads and the async/status family are reachable ...
        AssertExecute('Wicket - Read', Codeunit::"Bcmag Rpc Dispatcher", true);
        AssertExecute('Wicket - Read', Codeunit::"Bcmag Op Runner", true);
        AssertExecute('Wicket - Read', Codeunit::"Bcmag Op Authorizer", true);
        AssertExecute('Wicket - Read', Codeunit::"Bcmag Op Discover", true);
        AssertExecute('Wicket - Read', Codeunit::"Bcmag Op Describe", true);
        AssertExecute('Wicket - Read', Codeunit::"Bcmag Op Query", true);
        AssertExecute('Wicket - Read', Codeunit::"Bcmag Op Aggregate", true);
        AssertExecute('Wicket - Read', Codeunit::"Bcmag Op Read Blob", true);
        AssertExecute('Wicket - Read', Codeunit::"Bcmag Op Capabilities", true);
        AssertExecute('Wicket - Read', Codeunit::"Bcmag Op Skill", true);
        AssertExecute('Wicket - Read', Codeunit::"Bcmag Op Page Url", true);
        AssertExecute('Wicket - Read', Codeunit::"Bcmag Op Who Am I", true);
        AssertExecute('Wicket - Read', Codeunit::"Bcmag Op Status", true);
        AssertExecute('Wicket - Read', Codeunit::"Bcmag Op Requests", true);
        AssertExecute('Wicket - Read', Codeunit::"Bcmag Async Cancel", true);
        AssertExecute('Wicket - Read', Codeunit::"Bcmag Async Enqueuer", true);
        AssertExecute('Wicket - Read', Codeunit::"Bcmag Async Worker", true);
        AssertPageExecute('Wicket - Read', Page::"Bcmag Rpc Endpoint", true);
        // ... the write and invoke handlers are not.
        AssertExecute('Wicket - Read', Codeunit::"Bcmag Op Insert", false);
        AssertExecute('Wicket - Read', Codeunit::"Bcmag Op Modify", false);
        AssertExecute('Wicket - Read', Codeunit::"Bcmag Op Delete", false);
        AssertExecute('Wicket - Read', Codeunit::"Bcmag Op Invoke", false);
        AssertExecute('Wicket - Read', Codeunit::"Bcmag Op Action", false);
        AssertExecute('Wicket - Read', Codeunit::"Bcmag Action Rollback", false);
        AssertExecute('Wicket - Read', Codeunit::"Bcmag Log Purge", false);
        // No admin UI for a data-plane caller.
        AssertPageExecute('Wicket - Read', Page::"Bcmag Setup Card", false);
        AssertPageExecute('Wicket - Read', Page::"Bcmag Request Queue List", false);
        AssertPageExecute('Wicket - Read', Page::"Bcmag Operation Log List", false);
    end;

    [Test]
    procedure ReadRoleWritesOnlyItsOwnLogAndQueueRows()
    begin
        AssertTableData('Wicket - Read', Database::"Bcmag Operation Log", true, true, false, false);
        AssertTableData('Wicket - Read', Database::"Bcmag Idempotency Log", true, true, false, false);
        AssertTableData('Wicket - Read', Database::"Bcmag Request Queue", true, true, true, false);
        AssertTableData('Wicket - Read', Database::"Bcmag Idempotency Reservation", true, true, true, false);
        AssertTableData('Wicket - Read', Database::"Bcmag Setup", true, true, false, false);
        // Policy tables are read-only for the caller: it must never be able to self-authorise.
        AssertTableData('Wicket - Read', Database::"Bcmag Exposure", true, false, false, false);
        AssertTableData('Wicket - Read', Database::"Bcmag Field Exposure", true, false, false, false);
        AssertTableData('Wicket - Read', Database::"Bcmag Procedure Catalog", true, false, false, false);
        AssertTableData('Wicket - Read', Database::"Bcmag Action Catalog", true, false, false, false);
        AssertTableData('Wicket - Read', Database::"Tenant Media", true, false, false, false);
        // The read role names no business table and no wildcard.
        LibraryAssert.IsFalse(HasWildcardTableData('Wicket - Read'), 'Wicket - Read must not carry a tabledata wildcard');
    end;

    [Test]
    procedure ExecuteRoleAddsInvokeAndActionButNoWrites()
    begin
        AssertExecute('Wicket - Execute', Codeunit::"Bcmag Op Invoke", true);
        AssertExecute('Wicket - Execute', Codeunit::"Bcmag Op Action", true);
        AssertExecute('Wicket - Execute', Codeunit::"Bcmag Action Rollback", true);
        AssertExecute('Wicket - Execute', Codeunit::"Bcmag Invoke Context", true);
        AssertExecute('Wicket - Execute', Codeunit::"Bcmag Wrap Ping", true);
        AssertExecute('Wicket - Execute', Codeunit::"Bcmag Op Query", true); // inherited from Read
        AssertExecute('Wicket - Execute', Codeunit::"Bcmag Op Insert", false);
        AssertExecute('Wicket - Execute', Codeunit::"Bcmag Op Modify", false);
        AssertExecute('Wicket - Execute', Codeunit::"Bcmag Op Delete", false);
        AssertExecute('Wicket - Execute', Codeunit::"Bcmag Log Purge", false);
        AssertNoDeleteAnywhereExceptGates('Wicket - Execute');
    end;

    [Test]
    procedure EditRoleRunsEveryOperation()
    begin
        AssertExecute('Wicket - Edit', Codeunit::"Bcmag Op Insert", true);
        AssertExecute('Wicket - Edit', Codeunit::"Bcmag Op Modify", true);
        AssertExecute('Wicket - Edit', Codeunit::"Bcmag Op Delete", true);
        AssertExecute('Wicket - Edit', Codeunit::"Bcmag Value Coercer", true);
        AssertExecute('Wicket - Edit', Codeunit::"Bcmag Record Access", true);
        AssertExecute('Wicket - Edit', Codeunit::"Bcmag Op Invoke", true);   // inherited from Execute
        AssertExecute('Wicket - Edit', Codeunit::"Bcmag Op Query", true);    // inherited from Read
        AssertExecute('Wicket - Edit', Codeunit::"Bcmag Log Purge", false);  // maintenance is Admin
        // Still no policy writes and no deletes on Wicket's own tables: the caller cannot touch the
        // allowlist or erase the audit trail even with the full data-plane role.
        AssertTableData('Wicket - Edit', Database::"Bcmag Exposure", true, false, false, false);
        AssertTableData('Wicket - Edit', Database::"Bcmag Setup", true, true, false, false);
        AssertNoDeleteAnywhereExceptGates('Wicket - Edit');
    end;

    [Test]
    procedure AuditRoleSeesEverythingChangesNothing()
    begin
        AssertPageExecute('Wicket - Audit', Page::"Bcmag Setup Card", true);
        AssertPageExecute('Wicket - Audit', Page::"Bcmag Exposure List", true);
        AssertPageExecute('Wicket - Audit', Page::"Bcmag Field Exposure List", true);
        AssertPageExecute('Wicket - Audit', Page::"Bcmag Procedure Catalog List", true);
        AssertPageExecute('Wicket - Audit', Page::"Bcmag Action Catalog List", true);
        AssertPageExecute('Wicket - Audit', Page::"Bcmag Operation Log List", true);
        AssertPageExecute('Wicket - Audit', Page::"Bcmag Request Queue List", true);
        AssertPageExecute('Wicket - Audit', Page::"Bcmag Secret Input", false);
        AssertExecute('Wicket - Audit', Codeunit::"Bcmag Log Purge", false);
        AssertExecute('Wicket - Audit', Codeunit::"Bcmag Op Insert", false);
        AssertExecute('Wicket - Audit', Codeunit::"Bcmag Op Invoke", false);
        AssertTableData('Wicket - Audit', Database::"Bcmag Operation Log", true, false, false, false);
        AssertTableData('Wicket - Audit', Database::"Bcmag Idempotency Log", true, false, false, false);
        AssertTableData('Wicket - Audit', Database::"Bcmag Request Queue", true, false, false, false);
        AssertTableData('Wicket - Audit', Database::"Bcmag Idempotency Reservation", true, false, false, false);
        AssertTableData('Wicket - Audit', Database::"Bcmag Setup", true, false, false, false);
        AssertNoWritesAnywhere('Wicket - Audit');
    end;

    [Test]
    procedure AdminRoleOwnsTheControlPlane()
    begin
        AssertTableData('Wicket - Admin', Database::"Bcmag Setup", true, true, true, true);
        AssertTableData('Wicket - Admin', Database::"Bcmag Exposure", true, true, true, true);
        AssertTableData('Wicket - Admin', Database::"Bcmag Field Exposure", true, true, true, true);
        AssertTableData('Wicket - Admin', Database::"Bcmag Procedure Catalog", true, true, true, true);
        AssertTableData('Wicket - Admin', Database::"Bcmag Action Catalog", true, true, true, true);
        AssertTableData('Wicket - Admin', Database::"Bcmag Operation Log", true, true, true, true);
        AssertTableData('Wicket - Admin', Database::"Bcmag Idempotency Log", true, true, true, true);
        AssertTableData('Wicket - Admin', Database::"Bcmag Request Queue", true, true, true, true);
        AssertTableData('Wicket - Admin', Database::"Bcmag Idempotency Reservation", true, true, true, true);
        AssertExecute('Wicket - Admin', Codeunit::"Bcmag Log Purge", true);
        AssertPageExecute('Wicket - Admin', Page::"Bcmag Secret Input", true);
        AssertPageExecute('Wicket - Admin', Page::"Bcmag Setup Card", true);
        AssertExecute('Wicket - Admin', Codeunit::"Bcmag Op Delete", true);  // includes Edit
        // Admin is still Wicket-scoped: it grants nothing on business data.
        LibraryAssert.IsFalse(HasWildcardTableData('Wicket - Admin'), 'Wicket - Admin must not carry a tabledata wildcard');
    end;

    [Test]
    procedure DataReadGrantsReadOnEverythingAndNoCodeunitExecute()
    begin
        LibraryAssert.IsTrue(HasWildcardTableData('Wicket Data - Read'), 'Wicket Data - Read must grant tabledata * = R');
        AssertWildcardTableDataIsReadOnly('Wicket Data - Read');
        LibraryAssert.IsTrue(HasWildcardExecute('Wicket Data - Read', ObjTypePage()), 'Wicket Data - Read must grant page * = X');
        LibraryAssert.IsTrue(HasWildcardExecute('Wicket Data - Read', ObjTypeQuery()), 'Wicket Data - Read must grant query * = X');
        LibraryAssert.IsFalse(HasWildcardExecute('Wicket Data - Read', ObjTypeCodeunit()), 'Wicket Data - Read must NOT grant codeunit * = X');
        LibraryAssert.IsFalse(HasWildcardExecute('Wicket Data - Read', ObjTypeReport()), 'Wicket Data - Read must NOT grant report * = X');
        // It composes the RPC read plane, not the write plane.
        AssertExecute('Wicket Data - Read', Codeunit::"Bcmag Op Query", true);
        AssertExecute('Wicket Data - Read', Codeunit::"Bcmag Op Insert", false);
        AssertExecute('Wicket Data - Read', Codeunit::"Bcmag Op Invoke", false);
        AssertNoDeleteAnywhere('Wicket Data - Read');
    end;

    [Test]
    procedure DataExecuteGrantsExecuteEverywhereButNeverModifyOrDelete()
    begin
        LibraryAssert.IsTrue(HasWildcardExecute('Wicket Data - Exec', ObjTypeCodeunit()), 'Wicket Data - Exec must grant codeunit * = X');
        LibraryAssert.IsTrue(HasWildcardExecute('Wicket Data - Exec', ObjTypeReport()), 'Wicket Data - Exec must grant report * = X');
        LibraryAssert.IsTrue(HasWildcardExecute('Wicket Data - Exec', ObjTypeXmlPort()), 'Wicket Data - Exec must grant xmlport * = X');
        LibraryAssert.IsTrue(HasWildcardTableData('Wicket Data - Exec'), 'Wicket Data - Exec must inherit tabledata * = R');
        AssertWildcardTableDataIsReadOnly('Wicket Data - Exec');
        AssertExecute('Wicket Data - Exec', Codeunit::"Bcmag Op Invoke", true);
        AssertExecute('Wicket Data - Exec', Codeunit::"Bcmag Op Action", true);
        // `codeunit * = X` reaches the write handlers too — a permission set cannot carve an exception
        // out of a wildcard, and the earlier version of this test only "passed" because it looked the
        // wildcard row up by exact object id. HasExecute is wildcard-aware now, so say it honestly:
        AssertExecute('Wicket Data - Exec', Codeunit::"Bcmag Op Insert", true);
        AssertExecute('Wicket Data - Exec', Codeunit::"Bcmag Op Modify", true);
        AssertExecute('Wicket Data - Exec', Codeunit::"Bcmag Op Delete", true);
        // ...and what actually keeps insert/modify/delete closed to this role is the Write Gate: the
        // dispatcher refuses the write plane (403 role-forbidden) unless the caller can WRITE that
        // table, and only "Wicket - Edit" (and Admin) grant it. Here it is read-only via the wildcard.
        AssertTableData('Wicket Data - Exec', Database::"Bcmag Write Gate", true, false, false, false);
        AssertTableData('Wicket Data - Exec', Database::"Bcmag Execute Gate", true, true, true, true); // via Wicket - Execute
        // Logging tables stay writable (Insert) — the one place a read+execute role may write.
        AssertTableData('Wicket Data - Exec', Database::"Bcmag Operation Log", true, true, false, false);
        AssertTableData('Wicket Data - Exec', Database::"Bcmag Idempotency Log", true, true, false, false);
        AssertTableData('Wicket Data - Exec', Database::"Bcmag Request Queue", true, true, true, false);
        AssertTableData('Wicket Data - Exec', Database::"Bcmag Idempotency Reservation", true, true, true, false);
        AssertNoDeleteAnywhereExceptGates('Wicket Data - Exec');
    end;

    // ---- Role gates ------------------------------------------------------------------------------
    // Two empty sentinel tables turn "which rung is the caller on" into a question the platform answers:
    // the dispatcher checks Record.WritePermission on the Execute Gate before invoke/action and on the
    // Write Gate before insert/modify/delete, and answers a typed 403 role-forbidden instead of letting
    // the platform's Execute denial surface as a 500. A rung grants RIMD on its gate and nothing below
    // it does; a tabledata wildcard (Data - Read/Execute) yields Read only, which does not open a gate.

    [Test]
    procedure ExecuteGateOpensAtTheExecuteRungOnly()
    begin
        AssertTableData('Wicket - Read', Database::"Bcmag Execute Gate", false, false, false, false);
        AssertTableData('Wicket - Audit', Database::"Bcmag Execute Gate", false, false, false, false);
        AssertTableData('Wicket Data - Read', Database::"Bcmag Execute Gate", true, false, false, false);   // wildcard R only
        AssertTableData('Wicket - Execute', Database::"Bcmag Execute Gate", true, true, true, true);
        AssertTableData('Wicket - Edit', Database::"Bcmag Execute Gate", true, true, true, true);
        AssertTableData('Wicket - Admin', Database::"Bcmag Execute Gate", true, true, true, true);
        AssertTableData('Wicket Data - Exec', Database::"Bcmag Execute Gate", true, true, true, true);
    end;

    [Test]
    procedure WriteGateOpensAtTheEditRungOnly()
    begin
        AssertTableData('Wicket - Read', Database::"Bcmag Write Gate", false, false, false, false);
        AssertTableData('Wicket - Execute', Database::"Bcmag Write Gate", false, false, false, false);
        AssertTableData('Wicket - Audit', Database::"Bcmag Write Gate", false, false, false, false);
        AssertTableData('Wicket Data - Read', Database::"Bcmag Write Gate", true, false, false, false);     // wildcard R only
        AssertTableData('Wicket Data - Exec', Database::"Bcmag Write Gate", true, false, false, false);  // wildcard R only
        AssertTableData('Wicket - Edit', Database::"Bcmag Write Gate", true, true, true, true);
        AssertTableData('Wicket - Admin', Database::"Bcmag Write Gate", true, true, true, true);
    end;

    [Test]
    procedure GatesAreTheOnlyDeletableTablesBelowAdmin()
    begin
        // The gates carry no rows, so Delete on them is the rung signal, not a data right. Everything
        // else below Admin still cannot delete anything.
        AssertNoDeleteAnywhereExceptGates('Wicket - Read');
        AssertNoDeleteAnywhereExceptGates('Wicket - Execute');
        AssertNoDeleteAnywhereExceptGates('Wicket - Edit');
        AssertNoDeleteAnywhereExceptGates('Wicket Data - Read');
        AssertNoDeleteAnywhereExceptGates('Wicket Data - Exec');
    end;

    [Test]
    procedure EveryBcmagObjectIsCoveredByAdmin()
    var
        AllObj: Record AllObjWithCaption;
        Missing: Text;
    begin
        // Drift guard: a new table/codeunit/page in the Wicket range must be granted somewhere in the
        // ladder, and Admin is the union of it. Enums, interfaces and permission sets carry no grants.
        AllObj.SetRange("Object ID", 94100, 94199);
        AllObj.SetFilter("Object Type", '%1|%2|%3|%4|%5|%6',
            AllObj."Object Type"::Table, AllObj."Object Type"::Codeunit, AllObj."Object Type"::Page,
            AllObj."Object Type"::Report, AllObj."Object Type"::Query, AllObj."Object Type"::XMLport);
        if AllObj.FindSet() then
            repeat
                if not HasExecute('Wicket - Admin', PermObjectTypeOf(AllObj."Object Type"), AllObj."Object ID") then
                    Missing += StrSubstNo(' %1 %2 "%3";', Format(AllObj."Object Type"), AllObj."Object ID", AllObj."Object Name");
            until AllObj.Next() = 0;
        LibraryAssert.AreEqual('', Missing, StrSubstNo('Wicket objects without Execute in "Wicket - Admin" (add them to the ladder):%1', Missing));
    end;

    // ---- helpers -------------------------------------------------------------------------------

    local procedure AssertExecute(RoleId: Text; CodeunitId: Integer; Expected: Boolean)
    begin
        LibraryAssert.AreEqual(Expected, HasExecute(RoleId, ObjTypeCodeunit(), CodeunitId),
            StrSubstNo('"%1": Execute on codeunit %2 expected %3', RoleId, CodeunitId, Expected));
    end;

    local procedure AssertPageExecute(RoleId: Text; PageId: Integer; Expected: Boolean)
    begin
        LibraryAssert.AreEqual(Expected, HasExecute(RoleId, ObjTypePage(), PageId),
            StrSubstNo('"%1": Execute on page %2 expected %3', RoleId, PageId, Expected));
    end;

    local procedure AssertTableData(RoleId: Text; TableId: Integer; R: Boolean; I: Boolean; M: Boolean; D: Boolean)
    var
        Perm: Record "Expanded Permission";
        Found: Boolean;
    begin
        Found := FindRow(RoleId, ObjTypeTableData(), TableId, Perm);
        LibraryAssert.IsTrue(Found or not (R or I or M or D), StrSubstNo('"%1": no tabledata row for table %2', RoleId, TableId));
        if not Found then
            exit;
        LibraryAssert.AreEqual(R, Perm."Read Permission" = Perm."Read Permission"::Yes, StrSubstNo('"%1" table %2: Read expected %3', RoleId, TableId, R));
        LibraryAssert.AreEqual(I, Perm."Insert Permission" = Perm."Insert Permission"::Yes, StrSubstNo('"%1" table %2: Insert expected %3', RoleId, TableId, I));
        LibraryAssert.AreEqual(M, Perm."Modify Permission" = Perm."Modify Permission"::Yes, StrSubstNo('"%1" table %2: Modify expected %3', RoleId, TableId, M));
        LibraryAssert.AreEqual(D, Perm."Delete Permission" = Perm."Delete Permission"::Yes, StrSubstNo('"%1" table %2: Delete expected %3', RoleId, TableId, D));
    end;

    local procedure AssertNoDeleteAnywhere(RoleId: Text)
    var
        Perm: Record "Expanded Permission";
    begin
        FilterRole(RoleId, Perm);
        Perm.SetRange("Object Type", ObjTypeTableData());
        Perm.SetRange("Delete Permission", Perm."Delete Permission"::Yes);
        LibraryAssert.IsTrue(Perm.IsEmpty(), StrSubstNo('"%1" must not grant Delete on any table', RoleId));
    end;

    local procedure AssertNoWritesAnywhere(RoleId: Text)
    var
        Perm: Record "Expanded Permission";
    begin
        AssertNoDeleteAnywhere(RoleId);
        FilterRole(RoleId, Perm);
        Perm.SetRange("Object Type", ObjTypeTableData());
        Perm.SetRange("Insert Permission", Perm."Insert Permission"::Yes);
        LibraryAssert.IsTrue(Perm.IsEmpty(), StrSubstNo('"%1" must not grant Insert on any table', RoleId));
        Perm.SetRange("Insert Permission");
        Perm.SetRange("Modify Permission", Perm."Modify Permission"::Yes);
        LibraryAssert.IsTrue(Perm.IsEmpty(), StrSubstNo('"%1" must not grant Modify on any table', RoleId));
    end;

    // The wildcard's expanded form is platform-defined: it may surface as the single Object ID 0 row
    // or be enumerated per object. Accept either by probing a system table no Wicket set names.
    local procedure HasWildcardTableData(RoleId: Text): Boolean
    var
        Perm: Record "Expanded Permission";
    begin
        if FindRow(RoleId, ObjTypeTableData(), 0, Perm) then
            exit(Perm."Read Permission" = Perm."Read Permission"::Yes);
        if FindRow(RoleId, ObjTypeTableData(), Database::Company, Perm) then
            exit(Perm."Read Permission" = Perm."Read Permission"::Yes);
        exit(false);
    end;

    local procedure AssertWildcardTableDataIsReadOnly(RoleId: Text)
    var
        Perm: Record "Expanded Permission";
    begin
        if not FindRow(RoleId, ObjTypeTableData(), 0, Perm) then
            FindRow(RoleId, ObjTypeTableData(), Database::Company, Perm);
        LibraryAssert.AreEqual(Perm."Insert Permission"::" ", Perm."Insert Permission", StrSubstNo('"%1": the tabledata wildcard must not grant Insert', RoleId));
        LibraryAssert.AreEqual(Perm."Modify Permission"::" ", Perm."Modify Permission", StrSubstNo('"%1": the tabledata wildcard must not grant Modify', RoleId));
        LibraryAssert.AreEqual(Perm."Delete Permission"::" ", Perm."Delete Permission", StrSubstNo('"%1": the tabledata wildcard must not grant Delete', RoleId));
    end;

    local procedure HasWildcardExecute(RoleId: Text; ObjectType: Option): Boolean
    var
        Perm: Record "Expanded Permission";
    begin
        if FindRow(RoleId, ObjectType, 0, Perm) then
            exit(Perm."Execute Permission" = Perm."Execute Permission"::Yes);
        // Enumerated form: probe a Wicket object that only a wildcard (or Admin) would grant.
        case ObjectType of
            ObjTypeCodeunit():
                exit(HasExecute(RoleId, ObjectType, Codeunit::"Bcmag Log Purge"));
            ObjTypePage():
                exit(HasExecute(RoleId, ObjectType, Page::"Bcmag Setup Card"));
            ObjTypeQuery(), ObjTypeReport(), ObjTypeXmlPort():
                exit(false); // Wicket ships none of these, so only the Object ID 0 form can match
        end;
        exit(false);
    end;

    local procedure HasExecute(RoleId: Text; ObjectType: Option; ObjectId: Integer): Boolean
    var
        Perm: Record "Expanded Permission";
    begin
        if not FindRow(RoleId, ObjectType, ObjectId, Perm) then
            exit(false);
        exit(Perm."Execute Permission" = Perm."Execute Permission"::Yes);
    end;

    // Effective grant lookup. An explicit row for the object wins; failing that, the type's wildcard row
    // (Object ID 0 — how "codeunit * = X" / "tabledata * = R" expand) applies to every object of that
    // type. Without the fallback a wildcard set looked like it granted NOTHING on any named object, which
    // is how the original Data - Execute test asserted a handler boundary the wildcard does not have.
    local procedure FindRow(RoleId: Text; ObjectType: Option; ObjectId: Integer; var Perm: Record "Expanded Permission"): Boolean
    begin
        FilterRole(RoleId, Perm);
        Perm.SetRange("Object Type", ObjectType);
        Perm.SetRange("Object ID", ObjectId);
        if Perm.FindFirst() then
            exit(true);
        if ObjectId = 0 then
            exit(false);
        Perm.SetRange("Object ID", 0);
        exit(Perm.FindFirst());
    end;

    local procedure AssertNoDeleteAnywhereExceptGates(RoleId: Text)
    var
        Perm: Record "Expanded Permission";
    begin
        FilterRole(RoleId, Perm);
        Perm.SetRange("Object Type", ObjTypeTableData());
        Perm.SetRange("Delete Permission", Perm."Delete Permission"::Yes);
        Perm.SetFilter("Object ID", '<>%1&<>%2', Database::"Bcmag Execute Gate", Database::"Bcmag Write Gate");
        LibraryAssert.IsTrue(Perm.IsEmpty(), StrSubstNo('"%1" must not grant Delete on any table other than the role gates', RoleId));
    end;

    local procedure FilterRole(RoleId: Text; var Perm: Record "Expanded Permission")
    var
        AppId: Guid;
    begin
        Evaluate(AppId, BcmagAppIdTok);
        Perm.Reset();
        Perm.SetRange("App ID", AppId);
        Perm.SetRange("Role ID", CopyStr(RoleId, 1, MaxStrLen(Perm."Role ID")));
    end;

    local procedure PermObjectTypeOf(AllObjType: Option): Option
    var
        AllObj: Record AllObjWithCaption;
    begin
        case AllObjType of
            AllObj."Object Type"::Table:
                exit(ObjTypeTable());
            AllObj."Object Type"::Codeunit:
                exit(ObjTypeCodeunit());
            AllObj."Object Type"::Page:
                exit(ObjTypePage());
            AllObj."Object Type"::Report:
                exit(ObjTypeReport());
            AllObj."Object Type"::Query:
                exit(ObjTypeQuery());
            AllObj."Object Type"::XMLport:
                exit(ObjTypeXmlPort());
        end;
        exit(ObjTypeTableData());
    end;

    local procedure ObjTypeTableData(): Option
    var
        Perm: Record "Expanded Permission";
    begin
        exit(Perm."Object Type"::"Table Data");
    end;

    local procedure ObjTypeTable(): Option
    var
        Perm: Record "Expanded Permission";
    begin
        exit(Perm."Object Type"::Table);
    end;

    local procedure ObjTypeCodeunit(): Option
    var
        Perm: Record "Expanded Permission";
    begin
        exit(Perm."Object Type"::Codeunit);
    end;

    local procedure ObjTypePage(): Option
    var
        Perm: Record "Expanded Permission";
    begin
        exit(Perm."Object Type"::Page);
    end;

    local procedure ObjTypeReport(): Option
    var
        Perm: Record "Expanded Permission";
    begin
        exit(Perm."Object Type"::Report);
    end;

    local procedure ObjTypeQuery(): Option
    var
        Perm: Record "Expanded Permission";
    begin
        exit(Perm."Object Type"::Query);
    end;

    local procedure ObjTypeXmlPort(): Option
    var
        Perm: Record "Expanded Permission";
    begin
        exit(Perm."Object Type"::XMLport);
    end;
}
