codeunit 94357 "Bcmag Act Release Test"
{
    // release-sales / reopen-sales / release-purchase / reopen-purchase through the dispatcher's `action`
    // operation: the status moves the way the document page's actions move it, a repeat is a no-op that
    // says so, a document pending approval cannot be reopened, and a keyed call replays.
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibraryAssert: Codeunit "Library Assert";
        Helper: Codeunit "Bcmag Act Test Helper";

    [Test]
    procedure SalesOrderReleasesAndReopens()
    var
        SalesHeader: Record "Sales Header";
        Args, Response, Value : JsonObject;
        CustNo, GLAccNo : Code[20];
        Status: Integer;
    begin
        Helper.Initialize();
        Helper.FindSalesFixture(CustNo, GLAccNo);
        Helper.CreateSalesDoc("Sales Document Type"::Order, CustNo, GLAccNo, SalesHeader);

        Response := Helper.RunAction(Helper.ActionData('release-sales', SalesHeader.SystemId, Args), Helper.NewIdemKey(), Status);
        Helper.AssertCompleted(Status, Response, 'release');
        Value := Helper.ValueOf(Response);
        LibraryAssert.IsTrue(Helper.Bool(Value, 'released'), 'released: ' + Helper.Describe(Response));
        LibraryAssert.AreEqual('Released', Helper.Txt(Value, 'status'), 'status is the invariant name');
        LibraryAssert.IsTrue(Helper.Bool(Value, 'changed'), 'changed');
        LibraryAssert.AreEqual('Order', Helper.Txt(Value, 'sourceDocumentType'), 'sourceDocumentType');
        SalesHeader.Get(SalesHeader."Document Type", SalesHeader."No.");
        LibraryAssert.IsTrue(SalesHeader.Status = SalesHeader.Status::Released, 'the order is released');

        Response := Helper.RunAction(Helper.ActionData('release-sales', SalesHeader.SystemId, Args), Helper.NewIdemKey(), Status);
        Helper.AssertCompleted(Status, Response, 'release again');
        LibraryAssert.IsFalse(Helper.Bool(Helper.ValueOf(Response), 'changed'), 'a second release changes nothing and says so');

        Response := Helper.RunAction(Helper.ActionData('reopen-sales', SalesHeader.SystemId, Args), Helper.NewIdemKey(), Status);
        Helper.AssertCompleted(Status, Response, 'reopen');
        Value := Helper.ValueOf(Response);
        LibraryAssert.AreEqual('Open', Helper.Txt(Value, 'status'), 'status after reopen');
        LibraryAssert.IsTrue(Helper.Bool(Value, 'changed'), 'changed');
        SalesHeader.Get(SalesHeader."Document Type", SalesHeader."No.");
        LibraryAssert.IsTrue(SalesHeader.Status = SalesHeader.Status::Open, 'the order is open again');
    end;

    [Test]
    procedure PurchaseInvoiceReleasesAndReopensByDocumentNo()
    var
        PurchHeader: Record "Purchase Header";
        Args, Response : JsonObject;
        VendNo, GLAccNo : Code[20];
        Status: Integer;
    begin
        Helper.Initialize();
        Helper.FindPurchaseFixture(VendNo, GLAccNo);
        Helper.CreatePurchaseDoc("Purchase Document Type"::Invoice, VendNo, GLAccNo, PurchHeader);
        Args.Add('documentType', 'Invoice');
        Args.Add('no', PurchHeader."No.");

        Response := Helper.RunAction(Helper.ActionData('release-purchase', NoTarget(), Args), Helper.NewIdemKey(), Status);
        Helper.AssertCompleted(Status, Response, 'release purchase');
        LibraryAssert.AreEqual('Released', Helper.Txt(Helper.ValueOf(Response), 'status'), 'released: ' + Helper.Describe(Response));
        PurchHeader.Get(PurchHeader."Document Type", PurchHeader."No.");
        LibraryAssert.IsTrue(PurchHeader.Status = PurchHeader.Status::Released, 'the invoice is released');

        Response := Helper.RunAction(Helper.ActionData('reopen-purchase', NoTarget(), Args), Helper.NewIdemKey(), Status);
        Helper.AssertCompleted(Status, Response, 'reopen purchase');
        PurchHeader.Get(PurchHeader."Document Type", PurchHeader."No.");
        LibraryAssert.IsTrue(PurchHeader.Status = PurchHeader.Status::Open, 'the invoice is open again');
    end;

    [Test]
    procedure ReopenIsRefusedWhileApprovalIsPending()
    var
        SalesHeader: Record "Sales Header";
        Args, Response : JsonObject;
        CustNo, GLAccNo : Code[20];
        Status: Integer;
    begin
        Helper.Initialize();
        Helper.FindSalesFixture(CustNo, GLAccNo);
        Helper.CreateSalesDoc("Sales Document Type"::Order, CustNo, GLAccNo, SalesHeader);
        SalesHeader.Status := SalesHeader.Status::"Pending Approval";
        SalesHeader.Modify();

        Response := Helper.RunAction(Helper.ActionData('reopen-sales', SalesHeader.SystemId, Args), Helper.NewIdemKey(), Status);

        Helper.AssertProblem(Status, Response, 422, 'action-failed', 'reopen while pending approval');
        SalesHeader.Get(SalesHeader."Document Type", SalesHeader."No.");
        LibraryAssert.IsTrue(SalesHeader.Status = SalesHeader.Status::"Pending Approval", 'the status is untouched');
    end;

    [Test]
    procedure SameKeyReplaysTheRelease()
    var
        SalesHeader: Record "Sales Header";
        Args, Response, Replay : JsonObject;
        CustNo, GLAccNo : Code[20];
        IdemKey: Text;
        Status: Integer;
    begin
        Helper.Initialize();
        Helper.FindSalesFixture(CustNo, GLAccNo);
        Helper.CreateSalesDoc("Sales Document Type"::Invoice, CustNo, GLAccNo, SalesHeader);
        IdemKey := Helper.NewIdemKey();

        Response := Helper.RunAction(Helper.ActionData('release-sales', SalesHeader.SystemId, Args), IdemKey, Status);
        Helper.AssertCompleted(Status, Response, 'release');
        Replay := Helper.RunAction(Helper.ActionData('release-sales', SalesHeader.SystemId, Args), IdemKey, Status);
        Helper.AssertCompleted(Status, Replay, 'replay');
        LibraryAssert.IsTrue(Helper.Bool(Replay, '@replayed'), 'the same key replays: ' + Helper.Describe(Replay));
        LibraryAssert.IsTrue(Helper.Bool(Helper.ValueOf(Replay), 'changed'), 'the replay carries the original answer');
    end;

    local procedure NoTarget(): Guid
    var
        Empty: Guid;
    begin
        exit(Empty);
    end;
}
