codeunit 94351 "Bcmag Act Sales Test"
{
    // post-sales end to end through the dispatcher's `action` operation, against real sales documents
    // with G/L-account lines (no inventory needed). Also covers the framework behaviour an agent relies
    // on around a committing post: unknown documents, double posting, idempotent replay, preview gate.
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibraryAssert: Codeunit "Library Assert";
        Helper: Codeunit "Bcmag Act Test Helper";
        PostSalesTok: Label 'post-sales', Locked = true;

    [Test]
    procedure SalesOrderShipAndInvoicePostsAndDeletesTheOrder()
    var
        SalesHeader: Record "Sales Header";
        SalesInvHeader: Record "Sales Invoice Header";
        SalesShptHeader: Record "Sales Shipment Header";
        Args, Response, Value: JsonObject;
        CustNo, GLAccNo, OrderNo: Code[20];
        Status: Integer;
    begin
        Helper.Initialize();
        Helper.FindSalesFixture(CustNo, GLAccNo);
        Helper.CreateSalesDoc("Sales Document Type"::Order, CustNo, GLAccNo, SalesHeader);
        OrderNo := SalesHeader."No.";

        Args.Add('ship', true);
        Args.Add('invoice', true);
        Response := Helper.RunAction(Helper.ActionData(PostSalesTok, SalesHeader.SystemId, Args), '', Status);

        Helper.AssertOk(Status, Response, 'order ship+invoice');
        Value := Helper.ValueOf(Response);
        LibraryAssert.AreEqual('Order', Helper.Txt(Value, 'sourceDocumentType'), 'sourceDocumentType');
        LibraryAssert.AreEqual(OrderNo, Helper.Txt(Value, 'sourceNo'), 'sourceNo');
        LibraryAssert.IsTrue(SalesInvHeader.Get(Helper.Txt(Value, 'postedInvoiceNo')), 'postedInvoiceNo names a posted sales invoice: ' + Helper.Describe(Response));
        LibraryAssert.AreEqual(OrderNo, SalesInvHeader."Order No.", 'the posted invoice belongs to this order');
        LibraryAssert.IsTrue(SalesShptHeader.Get(Helper.Txt(Value, 'postedShipmentNo')), 'postedShipmentNo names a posted shipment: ' + Helper.Describe(Response));
        LibraryAssert.AreEqual(OrderNo, SalesShptHeader."Order No.", 'the shipment belongs to this order');
        LibraryAssert.IsFalse(SalesHeader.Get(SalesHeader."Document Type"::Order, OrderNo), 'a fully posted order is deleted');
    end;

    [Test]
    procedure SalesOrderShipThenInvoiceReportsEachPhaseOnce()
    var
        SalesHeader: Record "Sales Header";
        SalesInvHeader: Record "Sales Invoice Header";
        SalesShptHeader: Record "Sales Shipment Header";
        Args, Response, Value: JsonObject;
        CustNo, GLAccNo, OrderNo: Code[20];
        ShipmentNo: Text;
        Status: Integer;
    begin
        Helper.Initialize();
        Helper.FindSalesFixture(CustNo, GLAccNo);
        Helper.CreateSalesDoc("Sales Document Type"::Order, CustNo, GLAccNo, SalesHeader);
        OrderNo := SalesHeader."No.";

        // 1) ship only
        Args.Add('ship', true);
        Args.Add('invoice', false);
        Response := Helper.RunAction(Helper.ActionData(PostSalesTok, SalesHeader.SystemId, Args), '', Status);
        Helper.AssertOk(Status, Response, 'ship only');
        Value := Helper.ValueOf(Response);
        ShipmentNo := Helper.Txt(Value, 'postedShipmentNo');
        LibraryAssert.IsTrue(SalesShptHeader.Get(ShipmentNo), 'ship-only returns the shipment: ' + Helper.Describe(Response));
        LibraryAssert.IsFalse(Value.Contains('postedInvoiceNo'), 'ship-only produced no invoice: ' + Helper.Describe(Response));
        LibraryAssert.IsTrue(SalesHeader.Get(SalesHeader."Document Type"::Order, OrderNo), 'a shipped, uninvoiced order stays');

        // 2) invoice only, by documentType + no.
        Clear(Args);
        Args.Add('documentType', 'Order');
        Args.Add('no', OrderNo);
        Args.Add('ship', false);
        Args.Add('invoice', true);
        Response := Helper.RunAction(Helper.ActionData(PostSalesTok, CreateGuidNull(), Args), '', Status);
        Helper.AssertOk(Status, Response, 'invoice only');
        Value := Helper.ValueOf(Response);
        LibraryAssert.IsTrue(SalesInvHeader.Get(Helper.Txt(Value, 'postedInvoiceNo')), 'the second call returns the invoice: ' + Helper.Describe(Response));
        LibraryAssert.AreEqual(OrderNo, SalesInvHeader."Order No.", 'invoice belongs to this order');
        LibraryAssert.IsFalse(Value.Contains('postedShipmentNo'), 'the stale shipment stamp is not reported again: ' + Helper.Describe(Response));

        SalesShptHeader.Reset();
        SalesShptHeader.SetRange("Order No.", OrderNo);
        LibraryAssert.AreEqual(1, SalesShptHeader.Count(), 'exactly one shipment — no double shipment');
        SalesInvHeader.Reset();
        SalesInvHeader.SetRange("Order No.", OrderNo);
        LibraryAssert.AreEqual(1, SalesInvHeader.Count(), 'exactly one invoice');
        LibraryAssert.IsFalse(SalesHeader.Get(SalesHeader."Document Type"::Order, OrderNo), 'fully shipped + invoiced order is deleted');
    end;

    [Test]
    procedure SalesCreditMemoReturnsPostedCreditMemoNo()
    var
        SalesHeader: Record "Sales Header";
        SalesCrMemoHeader: Record "Sales Cr.Memo Header";
        Args, Response, Value: JsonObject;
        CustNo, GLAccNo, CrMemoNo: Code[20];
        Status: Integer;
    begin
        Helper.Initialize();
        Helper.FindSalesFixture(CustNo, GLAccNo);
        Helper.CreateSalesDoc("Sales Document Type"::"Credit Memo", CustNo, GLAccNo, SalesHeader);
        CrMemoNo := SalesHeader."No.";

        Args.Add('documentType', 'Credit Memo');
        Args.Add('no', CrMemoNo);
        Response := Helper.RunAction(Helper.ActionData(PostSalesTok, CreateGuidNull(), Args), '', Status);

        Helper.AssertOk(Status, Response, 'credit memo');
        Value := Helper.ValueOf(Response);
        LibraryAssert.AreEqual('Credit Memo', Helper.Txt(Value, 'sourceDocumentType'), 'sourceDocumentType');
        // Documented naming: postedInvoiceNo carries the posted CREDIT MEMO number for a credit memo.
        LibraryAssert.IsTrue(SalesCrMemoHeader.Get(Helper.Txt(Value, 'postedInvoiceNo')), 'postedInvoiceNo names a posted credit memo: ' + Helper.Describe(Response));
        LibraryAssert.AreEqual(CrMemoNo, SalesCrMemoHeader."Pre-Assigned No.", 'posted from this credit memo');
        LibraryAssert.IsFalse(SalesHeader.Get(SalesHeader."Document Type"::"Credit Memo", CrMemoNo), 'the posted credit memo is deleted');
    end;

    [Test]
    procedure PostingAMissingDocumentIsAClear4xx()
    var
        Args, Response: JsonObject;
        Status: Integer;
    begin
        Helper.Initialize();

        // by documentType + no.
        Args.Add('documentType', 'Order');
        Args.Add('no', 'BCMAGNOSUCHDOC');
        Response := Helper.RunAction(Helper.ActionData(PostSalesTok, CreateGuidNull(), Args), '', Status);
        Helper.AssertProblem(Status, Response, 422, 'action-failed', 'missing by no.');
        LibraryAssert.IsTrue(StrPos(Helper.Txt(Response, 'detail'), 'no sales header') > 0, 'detail names the miss: ' + Helper.Describe(Response));
        LibraryAssert.IsTrue(StrPos(Helper.Txt(Response, 'detail'), 'BCMAGNOSUCHDOC') > 0, 'detail names the document: ' + Helper.Describe(Response));

        // by target.systemId
        Clear(Args);
        Response := Helper.RunAction(Helper.ActionData(PostSalesTok, CreateGuid(), Args), '', Status);
        Helper.AssertProblem(Status, Response, 422, 'action-failed', 'missing by systemId');
        LibraryAssert.IsTrue(StrPos(Helper.Txt(Response, 'detail'), 'no sales header with systemId') > 0, 'detail names the miss: ' + Helper.Describe(Response));
    end;

    [Test]
    procedure DoublePostWithNewKeyFailsCleanlyAndSameKeyReplays()
    var
        SalesHeader: Record "Sales Header";
        SalesInvHeader: Record "Sales Invoice Header";
        CustLedgerEntry: Record "Cust. Ledger Entry";
        GLRegister: Record "G/L Register";
        Args, Response, Replay, Value: JsonObject;
        CustNo, GLAccNo, InvoiceNo: Code[20];
        PostedNo: Text;
        KeyA, KeyB: Text;
        SysId: Guid;
        Status, RegistersAfterFirst: Integer;
    begin
        Helper.Initialize();
        Helper.FindSalesFixture(CustNo, GLAccNo);
        Helper.CreateSalesDoc("Sales Document Type"::Invoice, CustNo, GLAccNo, SalesHeader);
        InvoiceNo := SalesHeader."No.";
        SysId := SalesHeader.SystemId;
        KeyA := Helper.NewIdemKey();
        KeyB := Helper.NewIdemKey();

        Response := Helper.RunAction(Helper.ActionData(PostSalesTok, SysId, Args), KeyA, Status);
        Helper.AssertOk(Status, Response, 'first post');
        PostedNo := Helper.Txt(Helper.ValueOf(Response), 'postedInvoiceNo');
        LibraryAssert.IsTrue(SalesInvHeader.Get(PostedNo), 'posted invoice exists: ' + Helper.Describe(Response));
        RegistersAfterFirst := GLRegister.Count();

        // Same key, same request: replayed from the snapshot, not executed again.
        Clear(Args);
        Replay := Helper.RunAction(Helper.ActionData(PostSalesTok, SysId, Args), KeyA, Status);
        LibraryAssert.AreEqual(200, Status, 'replay status: ' + Helper.Describe(Replay));
        LibraryAssert.IsTrue(Helper.Bool(Replay, '@replayed'), 'same key replays: ' + Helper.Describe(Replay));
        Value := Helper.ValueOf(Replay);
        LibraryAssert.AreEqual(PostedNo, Helper.Txt(Value, 'postedInvoiceNo'), 'the replay carries the original posted no.');
        LibraryAssert.AreEqual(Helper.Txt(Response, '@requestId'), Helper.Txt(Replay, '@requestId'), 'the replay carries the original @requestId');

        // A different key is a new request: the document is gone, so it fails cleanly and posts nothing.
        Clear(Args);
        Response := Helper.RunAction(Helper.ActionData(PostSalesTok, SysId, Args), KeyB, Status);
        Helper.AssertProblem(Status, Response, 422, 'action-failed', 'second post, new key');
        LibraryAssert.IsTrue(StrPos(Helper.Txt(Response, 'detail'), 'no sales header with systemId') > 0, 'detail says the document is gone: ' + Helper.Describe(Response));
        LibraryAssert.IsFalse(Helper.Bool(Response, '@replayed'), 'a new key is not a replay');

        SalesInvHeader.Reset();
        SalesInvHeader.SetRange("Pre-Assigned No.", InvoiceNo);
        LibraryAssert.AreEqual(1, SalesInvHeader.Count(), 'exactly one posted invoice for the source document');
        CustLedgerEntry.SetRange("Document No.", PostedNo);
        CustLedgerEntry.SetRange("Customer No.", CustNo);
        LibraryAssert.AreEqual(1, CustLedgerEntry.Count(), 'exactly one customer ledger entry');
        LibraryAssert.AreEqual(RegistersAfterFirst, GLRegister.Count(), 'neither the replay nor the failed repost created a G/L register');
    end;

    [Test]
    procedure PreviewIsRefusedWhereUnsupportedAndArgsPreviewIsReserved()
    var
        SalesHeader: Record "Sales Header";
        Args, Data, Response: JsonObject;
        CustNo, GLAccNo: Code[20];
        Status: Integer;
    begin
        Helper.Initialize();
        Helper.FindSalesFixture(CustNo, GLAccNo);
        Helper.CreateSalesDoc("Sales Document Type"::Invoice, CustNo, GLAccNo, SalesHeader);

        // data.preview = true on release-sales (enrolled with Preview Supported = false) → 400, nothing changed.
        Data := Helper.PreviewData('release-sales', SalesHeader.SystemId, Args);
        Response := Helper.RunAction(Data, '', Status);
        Helper.AssertProblem(Status, Response, 400, 'preview-unsupported', 'data.preview');
        SalesHeader.Get(SalesHeader."Document Type", SalesHeader."No.");
        LibraryAssert.IsTrue(SalesHeader.Status = SalesHeader.Status::Open, 'a refused preview changes nothing');

        // args.preview smuggled past the gate → 400 invalid-field, nothing posted.
        Clear(Args);
        Args.Add('preview', true);
        Response := Helper.RunAction(Helper.ActionData(PostSalesTok, SalesHeader.SystemId, Args), '', Status);
        Helper.AssertProblem(Status, Response, 400, 'invalid-field', 'args.preview');
        LibraryAssert.IsTrue(SalesHeader.Get(SalesHeader."Document Type", SalesHeader."No."), 'a refused args.preview posts nothing');
    end;

    local procedure CreateGuidNull(): Guid
    var
        Empty: Guid;
    begin
        exit(Empty);
    end;
}
