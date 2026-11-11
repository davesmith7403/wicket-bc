codeunit 94352 "Bcmag Act Purchase Test"
{
    // post-purchase end to end through the dispatcher's `action` operation.
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibraryAssert: Codeunit "Library Assert";
        Helper: Codeunit "Bcmag Act Test Helper";
        PostPurchaseTok: Label 'post-purchase', Locked = true;

    [Test]
    procedure PurchaseInvoicePostsAndReturnsThePostedInvoice()
    var
        PurchHeader: Record "Purchase Header";
        PurchInvHeader: Record "Purch. Inv. Header";
        VendLedgerEntry: Record "Vendor Ledger Entry";
        PurchRcptHeader: Record "Purch. Rcpt. Header";
        Args, Response, Value: JsonObject;
        VendNo, GLAccNo, InvoiceNo: Code[20];
        Status: Integer;
        NullGuid: Guid;
    begin
        Helper.Initialize();
        Helper.FindPurchaseFixture(VendNo, GLAccNo);
        Helper.CreatePurchaseDoc("Purchase Document Type"::Invoice, VendNo, GLAccNo, PurchHeader);
        InvoiceNo := PurchHeader."No.";

        Args.Add('documentType', 'Invoice');
        Args.Add('no', InvoiceNo);
        Response := Helper.RunAction(Helper.ActionData(PostPurchaseTok, NullGuid, Args), '', Status);

        Helper.AssertOk(Status, Response, 'purchase invoice');
        Value := Helper.ValueOf(Response);
        LibraryAssert.AreEqual('Invoice', Helper.Txt(Value, 'sourceDocumentType'), 'sourceDocumentType');
        LibraryAssert.AreEqual(InvoiceNo, Helper.Txt(Value, 'sourceNo'), 'sourceNo');
        LibraryAssert.IsTrue(PurchInvHeader.Get(Helper.Txt(Value, 'postedInvoiceNo')), 'postedInvoiceNo names a posted purchase invoice: ' + Helper.Describe(Response));
        LibraryAssert.AreEqual(InvoiceNo, PurchInvHeader."Pre-Assigned No.", 'posted from this invoice');
        // With Purchases & Payables Setup "Receipt on Invoice" on, posting an invoice also writes a posted
        // receipt; when the wrapper reports one it must be real and belong to this posting.
        if Value.Contains('postedReceiptNo') then begin
            LibraryAssert.IsTrue(PurchRcptHeader.Get(Helper.Txt(Value, 'postedReceiptNo')), 'postedReceiptNo names a posted receipt: ' + Helper.Describe(Response));
            LibraryAssert.AreEqual(VendNo, PurchRcptHeader."Buy-from Vendor No.", 'the receipt belongs to this vendor');
        end;
        LibraryAssert.IsFalse(PurchHeader.Get(PurchHeader."Document Type"::Invoice, InvoiceNo), 'the posted invoice is deleted');
        VendLedgerEntry.SetRange("Document No.", PurchInvHeader."No.");
        VendLedgerEntry.SetRange("Vendor No.", VendNo);
        LibraryAssert.AreEqual(1, VendLedgerEntry.Count(), 'one vendor ledger entry');
    end;

    [Test]
    procedure AnInvoiceThatDisagreesWithItsIncomingDocumentIsNotPosted()
    var
        PurchHeader: Record "Purchase Header";
        IncomingDocument: Record "Incoming Document";
        Args, Response: JsonObject;
        VendNo, GLAccNo: Code[20];
        Status: Integer;
        EntryNo: Integer;
    begin
        // The invoice page refuses to post an invoice whose total differs from the amount of the incoming
        // document it is linked to (Purchase Header.IsTotalValid). Purch.-Post does not check it.
        Helper.Initialize();
        Helper.FindPurchaseFixture(VendNo, GLAccNo);
        Helper.CreatePurchaseDoc("Purchase Document Type"::Invoice, VendNo, GLAccNo, PurchHeader);
        if IncomingDocument.FindLast() then
            EntryNo := IncomingDocument."Entry No.";
        EntryNo += 1;
        IncomingDocument.Init();
        IncomingDocument."Entry No." := EntryNo;
        IncomingDocument."Amount Incl. VAT" := 987654.32;
        IncomingDocument.Insert();
        PurchHeader."Incoming Document Entry No." := EntryNo;
        PurchHeader.Modify();

        Response := Helper.RunAction(Helper.ActionData(PostPurchaseTok, PurchHeader.SystemId, Args), '', Status);

        Helper.AssertProblem(Status, Response, 422, 'action-failed', 'a total that disagrees with the incoming document');
        LibraryAssert.IsTrue(StrPos(Helper.Txt(Response, 'detail'), 'incoming document') > 0, 'the refusal says what disagrees: ' + Helper.Describe(Response));
        LibraryAssert.IsTrue(PurchHeader.Get(PurchHeader."Document Type", PurchHeader."No."), 'the invoice is not posted');

        // Without the link the same invoice posts: the refusal was the total check and nothing else.
        PurchHeader."Incoming Document Entry No." := 0;
        PurchHeader.Modify();
        IncomingDocument.Get(EntryNo);
        IncomingDocument.Delete();
        Response := Helper.RunAction(Helper.ActionData(PostPurchaseTok, PurchHeader.SystemId, Args), '', Status);
        Helper.AssertOk(Status, Response, 'the same invoice without the link');
    end;
}
