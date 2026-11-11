codeunit 94354 "Bcmag Act Restricted Test"
{
    // The rest of the companion suite runs as SUPER. These tests call the dispatcher as a principal that
    // holds exactly the sets a least-privilege setup names (Microsoft's Permissions Mock): "Wicket Data -
    // Read" + "Wicket - Execute" + "Wicket Actions" + Business Central's own D365 BASIC. The mock is given
    // no "All Objects" set, so nothing but the named sets can supply a right.
    //
    // Why D365 BASIC is part of it: "Wicket Actions" grants execute on the wrappers and on the Base
    // Application entry points they call, but Business Central also checks execute on every codeunit
    // those call in turn. In a fresh session the three Wicket sets alone answer item-availability with
    // 422 action-failed naming the first such codeunit (proven by hand, 2026-11-10). That is not a test
    // here: the platform checks execute on a codeunit only the first time it runs in a session, so the
    // answer depends on what ran before — after the SUPER tests of this suite it is 200. Only facts that
    // hold in any order are asserted: the role gate, the table rights, and that the full set works.
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibraryAssert: Codeunit "Library Assert";
        Helper: Codeunit "Bcmag Act Test Helper";
        PermissionsMock: Codeunit "Permissions Mock";
        DataReadSetTok: Label 'Wicket Data - Read', Locked = true;
        ExecuteSetTok: Label 'Wicket - Execute', Locked = true;
        ActSetTok: Label 'Wicket Act', Locked = true;
        RigSetTok: Label 'Wicket Act Test Rig', Locked = true;
        BasicSetTok: Label 'D365 BASIC', Locked = true;

    [Test]
    procedure WithBusinessCentralsBasicSetItemAvailabilityRuns()
    var
        Response: JsonObject;
        Status: Integer;
    begin
        Response := RunItemAvailabilityAs(DataReadSetTok + '|' + ExecuteSetTok + '|' + ActSetTok + '|' + BasicSetTok, Status);
        Helper.AssertCompleted(Status, Response, 'item-availability as Data - Read + Execute + Wicket Actions + D365 BASIC');
    end;

    [Test]
    procedure WithoutTheExecuteRungAnActionIsRoleForbidden()
    var
        Response: JsonObject;
        Status: Integer;
    begin
        Response := RunItemAvailabilityAs(DataReadSetTok + '|' + ActSetTok + '|' + BasicSetTok, Status);
        Helper.AssertProblem(Status, Response, 403, 'role-forbidden', 'Data - Read + Wicket Actions + D365 BASIC, no Execute rung');
    end;

    [Test]
    procedure LeastPrivilegeSetsCannotPostButAreAnsweredTyped()
    var
        SalesHeader: Record "Sales Header";
        SalesLine: Record "Sales Line";
        Args, Response: JsonObject;
        CustNo, GLAccNo: Code[20];
        Status: Integer;
    begin
        // Wicket Actions grants no posting data rights, and D365 BASIC posts nothing either: those rights
        // come from Business Central's own posting sets.
        Helper.Initialize();
        Helper.FindSalesFixture(CustNo, GLAccNo);
        Helper.CreateSalesDoc("Sales Document Type"::Invoice, CustNo, GLAccNo, SalesHeader);
        Commit();
        Become(DataReadSetTok + '|' + ExecuteSetTok + '|' + ActSetTok + '|' + BasicSetTok);
        Response := Helper.RunAction(Helper.ActionData('post-sales', SalesHeader.SystemId, Args), Helper.NewIdemKey(), Status);
        PermissionsMock.Stop();
        Helper.AssertProblem(Status, Response, 422, 'action-failed', 'posting without posting rights');
        // Every wrapper failure is a 422: the text shows it was the poster that failed, not the lookup
        // of the document or the approval check before it.
        LibraryAssert.IsTrue(StrPos(Helper.Txt(Response, 'detail'), 'posting sales Invoice') = 1, 'the call reached Sales-Post: ' + Helper.Describe(Response));
        LibraryAssert.IsTrue(SalesHeader.Get(SalesHeader."Document Type", SalesHeader."No."), 'and the invoice is still there, unposted');
        // Without the delete triggers: they fill number-series gaps with archive documents and say so
        // in a message.
        SalesLine.SetRange("Document Type", SalesHeader."Document Type");
        SalesLine.SetRange("Document No.", SalesHeader."No.");
        SalesLine.DeleteAll(false);
        SalesHeader.Delete(false);
        Commit();
    end;

    local procedure RunItemAvailabilityAs(Sets: Text; var Status: Integer) Response: JsonObject
    var
        Args, Data: JsonObject;
        NoTarget: Guid;
        LocationCode: Code[10];
        ItemNo: Code[20];
    begin
        Helper.Initialize();
        Helper.FindItemFixture(ItemNo, LocationCode);
        Args.Add('itemNo', ItemNo);
        Args.Add('locationCode', LocationCode);
        Args.Add('date', Format(WorkDate(), 0, 9));
        Args.Add('quantity', 1);
        Data := Helper.ActionData('item-availability', NoTarget, Args);
        Commit();
        Become(Sets);
        Response := Helper.RunAction(Data, '', Status);
        PermissionsMock.Stop();
    end;

    // From here until PermissionsMock.Stop() the session holds exactly the named sets and the test rig.
    local procedure Become(Sets: Text)
    var
        RoleId: Text;
        First: Boolean;
    begin
        PermissionsMock.Start();
        First := true;
        foreach RoleId in Sets.Split('|') do begin
            if First then
                PermissionsMock.SetExactPermissionSet(CopyStr(RoleId, 1, 20))
            else
                PermissionsMock.Assign(CopyStr(RoleId, 1, 20));
            First := false;
        end;
        PermissionsMock.Assign(RigSetTok);
    end;
}
