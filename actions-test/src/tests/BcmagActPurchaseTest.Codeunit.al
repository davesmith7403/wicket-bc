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
}
