codeunit 94356 "Bcmag Act Preview Test"
{
    // preview: true on the four posting verbs, end to end through the dispatcher's `action` operation:
    // the entries Business Central would create come back, nothing is written (proven by re-reading the
    // database), a failing preview names the reason, the real post matches the preview, and a preview
    // runs on a read-only endpoint where the real post is refused.
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibraryAssert: Codeunit "Library Assert";
        Helper: Codeunit "Bcmag Act Test Helper";
        PostSalesTok: Label 'post-sales', Locked = true;
        PostPurchaseTok: Label 'post-purchase', Locked = true;
        PostGenJournalTok: Label 'post-gen-journal', Locked = true;
        PostItemJournalTok: Label 'post-item-journal', Locked = true;

    [Test]
    procedure SalesInvoicePreviewReturnsTheEntriesAndWritesNothing()
    var
        SalesHeader: Record "Sales Header";
        SalesInvHeader: Record "Sales Invoice Header";
        GLRegister: Record "G/L Register";
        NoSeries: Codeunit "No. Series";
        Args, Response, Value, Entry : JsonObject;
        CustNo, GLAccNo, DocNo, PostingSeries, NextNoBefore : Code[20];
        Registers, LastGLEntryNo, Status : Integer;
    begin
        Helper.Initialize();
        Helper.FindSalesFixture(CustNo, GLAccNo);
        Helper.CreateSalesDoc("Sales Document Type"::Invoice, CustNo, GLAccNo, SalesHeader);
        DocNo := SalesHeader."No.";
        SalesHeader.CalcFields("Amount Including VAT");
        PostingSeries := SalesPostingNoSeries(SalesHeader);
        NextNoBefore := NoSeries.PeekNextNo(PostingSeries);
        LastGLEntryNo := LastGLEntry();
        Registers := GLRegister.Count();

        Response := Helper.RunAction(Helper.PreviewData(PostSalesTok, SalesHeader.SystemId, Args), '', Status);

        Helper.AssertCompleted(Status, Response, 'sales preview');
        Value := Helper.ValueOf(Response);
        LibraryAssert.IsTrue(Helper.Bool(Value, 'preview'), 'marked as a preview');
        LibraryAssert.IsTrue(Helper.Bool(Value, 'wouldPost'), 'the invoice would post: ' + Helper.Describe(Response));
        LibraryAssert.AreEqual(0, Helper.ArrayCount(Value, 'errors'), 'no errors');
        LibraryAssert.AreEqual('Invoice', Helper.Txt(Value, 'sourceDocumentType'), 'sourceDocumentType');
        LibraryAssert.AreEqual(DocNo, Helper.Txt(Value, 'sourceNo'), 'sourceNo');
        LibraryAssert.IsTrue(Helper.FindEntry(Value, Database::"G/L Entry", Entry), 'G/L entries previewed: ' + Helper.Describe(Response));
        LibraryAssert.AreEqual('G/L Entry', Helper.Txt(Entry, 'table'), 'the invariant table name');
        LibraryAssert.AreEqual(Helper.Dec(Entry, 'debit'), Helper.Dec(Entry, 'credit'), 'the G/L entries balance');
        LibraryAssert.AreEqual(SalesHeader."Amount Including VAT", Helper.Dec(Entry, 'debit'), 'debit = total incl. VAT');
        LibraryAssert.IsTrue(Helper.FindEntry(Value, Database::"Detailed Cust. Ledg. Entry", Entry), 'receivable previewed');
        LibraryAssert.AreEqual(SalesHeader."Amount Including VAT", Helper.Dec(Entry, 'amount'), 'receivable = total incl. VAT');
        LibraryAssert.IsTrue(Helper.ArrayCount(Value, 'glAccounts') >= 2, 'the G/L accounts it would hit: ' + Helper.Describe(Response));

        LibraryAssert.AreEqual(LastGLEntryNo, LastGLEntry(), 'no G/L entry persisted');
        LibraryAssert.AreEqual(Registers, GLRegister.Count(), 'no G/L register persisted');
        SalesInvHeader.SetRange("Pre-Assigned No.", DocNo);
        LibraryAssert.IsTrue(SalesInvHeader.IsEmpty(), 'no posted invoice');
        LibraryAssert.IsTrue(SalesHeader.Get(SalesHeader."Document Type", DocNo), 'the invoice is still open');
        LibraryAssert.AreEqual(NextNoBefore, NoSeries.PeekNextNo(PostingSeries), 'the posted-invoice no. series was not consumed');
    end;

    [Test]
    procedure RealPostMatchesThePreview()
    var
        SalesHeader: Record "Sales Header";
        GLEntry: Record "G/L Entry";
        Args, Response, Value, Entry : JsonObject;
        CustNo, GLAccNo : Code[20];
        PostedNo: Text;
        PreviewedCount, Status : Integer;
        PreviewedDebit: Decimal;
    begin
        Helper.Initialize();
        Helper.FindSalesFixture(CustNo, GLAccNo);
        Helper.CreateSalesDoc("Sales Document Type"::Invoice, CustNo, GLAccNo, SalesHeader);

        Response := Helper.RunAction(Helper.PreviewData(PostSalesTok, SalesHeader.SystemId, Args), '', Status);
        Helper.AssertCompleted(Status, Response, 'preview');
        Value := Helper.ValueOf(Response);
        LibraryAssert.IsTrue(Helper.FindEntry(Value, Database::"G/L Entry", Entry), 'G/L entries previewed: ' + Helper.Describe(Response));
        PreviewedCount := Helper.Int(Entry, 'count');
        PreviewedDebit := Helper.Dec(Entry, 'debit');

        Response := Helper.RunAction(Helper.ActionData(PostSalesTok, SalesHeader.SystemId, Args), Helper.NewIdemKey(), Status);
        Helper.AssertOk(Status, Response, 'real post after the preview');
        PostedNo := Helper.Txt(Helper.ValueOf(Response), 'postedInvoiceNo');
        GLEntry.SetRange("Document No.", PostedNo);
        LibraryAssert.AreEqual(PreviewedCount, GLEntry.Count(), 'the post created as many G/L entries as previewed');
        GLEntry.CalcSums("Debit Amount");
        LibraryAssert.AreEqual(PreviewedDebit, GLEntry."Debit Amount", 'and debited what the preview said');
    end;

    [Test]
    procedure FailingPreviewNamesTheReasonAndWritesNothing()
    var
        SalesHeader: Record "Sales Header";
        GLSetup: Record "General Ledger Setup";
        GLRegister: Record "G/L Register";
        Args, Response, Value : JsonObject;
        CustNo, GLAccNo : Code[20];
        Registers, Status : Integer;
    begin
        Helper.Initialize();
        Helper.FindSalesFixture(CustNo, GLAccNo);
        Helper.CreateSalesDoc("Sales Document Type"::Invoice, CustNo, GLAccNo, SalesHeader);
        GLSetup.Get();
        GLSetup."Allow Posting From" := SalesHeader."Posting Date" + 1;
        GLSetup."Allow Posting To" := SalesHeader."Posting Date" + 1;
        GLSetup.Modify();
        Registers := GLRegister.Count();

        Response := Helper.RunAction(Helper.PreviewData(PostSalesTok, SalesHeader.SystemId, Args), '', Status);

        // The preview did its job: it is a completed call that says the post would fail, and why.
        Helper.AssertCompleted(Status, Response, 'a failing preview');
        Value := Helper.ValueOf(Response);
        LibraryAssert.IsFalse(Helper.Bool(Value, 'wouldPost'), 'wouldPost false: ' + Helper.Describe(Response));
        LibraryAssert.IsTrue(Helper.ArrayCount(Value, 'errors') > 0, 'the reason is returned: ' + Helper.Describe(Response));
        LibraryAssert.AreEqual(Registers, GLRegister.Count(), 'no G/L register persisted');
        LibraryAssert.IsTrue(SalesHeader.Get(SalesHeader."Document Type", SalesHeader."No."), 'the invoice is still open');
    end;

    [Test]
    procedure PurchaseInvoicePreviewReturnsThePayable()
    var
        PurchHeader: Record "Purchase Header";
        PurchInvHeader: Record "Purch. Inv. Header";
        Args, Response, Value, Entry : JsonObject;
        VendNo, GLAccNo, DocNo : Code[20];
        Status: Integer;
    begin
        Helper.Initialize();
        Helper.FindPurchaseFixture(VendNo, GLAccNo);
        Helper.CreatePurchaseDoc("Purchase Document Type"::Invoice, VendNo, GLAccNo, PurchHeader);
        DocNo := PurchHeader."No.";
        PurchHeader.CalcFields("Amount Including VAT");

        Response := Helper.RunAction(Helper.PreviewData(PostPurchaseTok, PurchHeader.SystemId, Args), '', Status);

        Helper.AssertCompleted(Status, Response, 'purchase preview');
        Value := Helper.ValueOf(Response);
        LibraryAssert.IsTrue(Helper.Bool(Value, 'wouldPost'), 'the invoice would post: ' + Helper.Describe(Response));
        LibraryAssert.IsTrue(Helper.FindEntry(Value, Database::"Detailed Vendor Ledg. Entry", Entry), 'payable previewed: ' + Helper.Describe(Response));
        LibraryAssert.AreEqual(-PurchHeader."Amount Including VAT", Helper.Dec(Entry, 'amount'), 'payable = minus the total incl. VAT');
        PurchInvHeader.SetRange("Pre-Assigned No.", DocNo);
        LibraryAssert.IsTrue(PurchInvHeader.IsEmpty(), 'no posted purchase invoice');
        LibraryAssert.IsTrue(PurchHeader.Get(PurchHeader."Document Type", DocNo), 'the invoice is still open');
    end;

    [Test]
    procedure GeneralJournalPreviewLeavesTheBatchUntouched()
    var
        GenJnlLine: Record "Gen. Journal Line";
        GLEntry: Record "G/L Entry";
        Args, Response, Value, Entry : JsonObject;
        Template, Batch : Code[10];
        AccNo1, AccNo2, DocNo : Code[20];
        Status: Integer;
    begin
        Helper.Initialize();
        Helper.FindBalanceAccounts(AccNo1, AccNo2);
        Helper.CreateGenJnlBatch(Template, Batch);
        DocNo := Helper.NewDocNo();
        Helper.AddGenJnlLine(Template, Batch, 10000, DocNo, AccNo1, 100);
        Helper.AddGenJnlLine(Template, Batch, 20000, DocNo, AccNo2, -100);
        Args.Add('template', Template);
        Args.Add('batch', Batch);

        Response := Helper.RunAction(Helper.PreviewData(PostGenJournalTok, NoTarget(), Args), '', Status);

        Helper.AssertCompleted(Status, Response, 'general journal preview');
        Value := Helper.ValueOf(Response);
        LibraryAssert.IsTrue(Helper.Bool(Value, 'wouldPost'), 'the batch would post: ' + Helper.Describe(Response));
        LibraryAssert.AreEqual(Batch, Helper.Txt(Value, 'batch'), 'batch echoed');
        LibraryAssert.IsTrue(Helper.FindEntry(Value, Database::"G/L Entry", Entry), 'G/L entries previewed: ' + Helper.Describe(Response));
        LibraryAssert.AreEqual(2, Helper.Int(Entry, 'count'), 'one G/L entry per line');
        LibraryAssert.AreEqual(100, Helper.Dec(Entry, 'debit'), 'debit');
        GLEntry.SetRange("Document No.", DocNo);
        LibraryAssert.IsTrue(GLEntry.IsEmpty(), 'nothing posted');
        GenJnlLine.SetRange("Journal Template Name", Template);
        GenJnlLine.SetRange("Journal Batch Name", Batch);
        LibraryAssert.AreEqual(2, GenJnlLine.Count(), 'both lines are still in the batch');
    end;

    [Test]
    procedure ItemJournalPreviewReturnsTheItemLedgerEntry()
    var
        ItemJnlLine: Record "Item Journal Line";
        ItemLedgerEntry: Record "Item Ledger Entry";
        Args, Response, Value, Entry : JsonObject;
        Template, Batch, LocationCode : Code[10];
        ItemNo, DocNo : Code[20];
        Status: Integer;
    begin
        Helper.Initialize();
        Helper.FindItemFixture(ItemNo, LocationCode);
        Helper.CreateItemJnlBatch(Template, Batch);
        DocNo := Helper.NewDocNo();
        Helper.AddItemJnlLine(Template, Batch, DocNo, ItemNo, LocationCode, 3);
        Args.Add('template', Template);
        Args.Add('batch', Batch);

        Response := Helper.RunAction(Helper.PreviewData(PostItemJournalTok, NoTarget(), Args), '', Status);

        Helper.AssertCompleted(Status, Response, 'item journal preview');
        Value := Helper.ValueOf(Response);
        LibraryAssert.IsTrue(Helper.Bool(Value, 'wouldPost'), 'the batch would post: ' + Helper.Describe(Response));
        LibraryAssert.IsTrue(Helper.FindEntry(Value, Database::"Item Ledger Entry", Entry), 'item ledger entry previewed: ' + Helper.Describe(Response));
        LibraryAssert.AreEqual(3, Helper.Dec(Entry, 'quantity'), 'quantity');
        ItemLedgerEntry.SetRange("Item No.", ItemNo);
        ItemLedgerEntry.SetRange("Document No.", DocNo);
        LibraryAssert.IsTrue(ItemLedgerEntry.IsEmpty(), 'nothing posted');
        ItemJnlLine.SetRange("Journal Template Name", Template);
        ItemJnlLine.SetRange("Journal Batch Name", Batch);
        LibraryAssert.AreEqual(1, ItemJnlLine.Count(), 'the line is still in the batch');
    end;

    [Test]
    procedure PreviewRunsOnAReadOnlyEndpointWhereThePostIsRefused()
    var
        SalesHeader: Record "Sales Header";
        Setup: Record "Bcmag Setup";
        Args, Response : JsonObject;
        CustNo, GLAccNo : Code[20];
        Status: Integer;
    begin
        Helper.Initialize();
        Helper.FindSalesFixture(CustNo, GLAccNo);
        Helper.CreateSalesDoc("Sales Document Type"::Invoice, CustNo, GLAccNo, SalesHeader);
        Setup.GetSingleton();
        Setup."Read-Only Mode" := true;
        Setup.Modify(true);

        Response := Helper.RunAction(Helper.PreviewData(PostSalesTok, SalesHeader.SystemId, Args), '', Status);
        Helper.AssertCompleted(Status, Response, 'a preview on a read-only endpoint');
        LibraryAssert.IsTrue(Helper.Bool(Helper.ValueOf(Response), 'wouldPost'), 'and it previews: ' + Helper.Describe(Response));

        Response := Helper.RunAction(Helper.ActionData(PostSalesTok, SalesHeader.SystemId, Args), Helper.NewIdemKey(), Status);
        Helper.AssertProblem(Status, Response, 403, 'read-only', 'the real post');
        LibraryAssert.IsTrue(SalesHeader.Get(SalesHeader."Document Type", SalesHeader."No."), 'nothing posted');

        Setup.GetSingleton();
        Setup."Read-Only Mode" := false;
        Setup.Modify(true);
    end;

    local procedure SalesPostingNoSeries(SalesHeader: Record "Sales Header"): Code[20]
    var
        SalesSetup: Record "Sales & Receivables Setup";
    begin
        if SalesHeader."Posting No. Series" <> '' then
            exit(SalesHeader."Posting No. Series");
        SalesSetup.Get();
        exit(SalesSetup."Posted Invoice Nos.");
    end;

    local procedure LastGLEntry(): Integer
    var
        GLEntry: Record "G/L Entry";
    begin
        if GLEntry.FindLast() then
            exit(GLEntry."Entry No.");
    end;

    local procedure NoTarget(): Guid
    var
        Empty: Guid;
    begin
        exit(Empty);
    end;
}
