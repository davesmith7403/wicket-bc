codeunit 94207 "Bcmag Act Preview"
{
    // Real posting previews for the posting wrappers, on Business Central's own preview engine: codeunit
    // 19 "Gen. Jnl.-Post Preview" through its no-UI path (SetContext + instance Run). OnRun hides the
    // G/L Posting Preview page, PreviewStart forbids commits, the posting routine in preview mode ends
    // with its preview error, and OnRun closes with Error('') so everything inside rolls back. The would-be
    // entries survive in the temporary tables of the bound Posting Preview Event Handler. Proven headless
    // in a spike before this was built.
    // The action op runs a preview inside its own forced rollback as well (Bcmag Action Rollback).
    //
    // result: { preview: true, wouldPost, errors: [text], entries: [{ table, tableId, count, debit?, credit?,
    //           amount?, base?, quantity?, costAmount?, salesAmount? }], glAccounts: [{ no, debit, credit }] }
    // `table` is the invariant table name; message texts follow the session language.

    procedure PreviewSales(var SalesHeader: Record "Sales Header") Result: JsonObject
    var
        SalesPostYesNo: Codeunit "Sales-Post (Yes/No)";
        Capture: Codeunit "Bcmag Act Preview Capture";
    begin
        Capture.SetSalesFlags(SalesHeader.Ship, SalesHeader.Invoice, SalesHeader.Receive);
        BindSubscription(SalesPostYesNo);
        Result := Run(SalesPostYesNo, SalesHeader, Capture);
        UnbindSubscription(SalesPostYesNo);
    end;

    procedure PreviewPurchase(var PurchHeader: Record "Purchase Header") Result: JsonObject
    var
        PurchPostYesNo: Codeunit "Purch.-Post (Yes/No)";
        Capture: Codeunit "Bcmag Act Preview Capture";
    begin
        Capture.SetPurchaseFlags(PurchHeader.Receive, PurchHeader.Invoice, PurchHeader.Ship);
        BindSubscription(PurchPostYesNo);
        Result := Run(PurchPostYesNo, PurchHeader, Capture);
        UnbindSubscription(PurchPostYesNo);
    end;

    procedure PreviewGenJournal(var GenJnlLine: Record "Gen. Journal Line") Result: JsonObject
    var
        GenJnlPost: Codeunit "Gen. Jnl.-Post";
        Capture: Codeunit "Bcmag Act Preview Capture";
    begin
        BindSubscription(GenJnlPost);
        Result := Run(GenJnlPost, GenJnlLine, Capture);
        UnbindSubscription(GenJnlPost);
    end;

    procedure PreviewItemJournal(var ItemJnlLine: Record "Item Journal Line") Result: JsonObject
    var
        ItemJnlPost: Codeunit "Item Jnl.-Post";
        Capture: Codeunit "Bcmag Act Preview Capture";
    begin
        BindSubscription(ItemJnlPost);
        Result := Run(ItemJnlPost, ItemJnlLine, Capture);
        UnbindSubscription(ItemJnlPost);
    end;

    local procedure Run(Subscriber: Variant; RecVar: Variant; var Capture: Codeunit "Bcmag Act Preview Capture") Result: JsonObject
    var
        TempDocumentEntry: Record "Document Entry" temporary;
        GenJnlPostPreview: Codeunit "Gen. Jnl.-Post Preview";
        Handler: Codeunit "Posting Preview Event Handler";
        Entries, Errors, GLAccounts : JsonArray;
        Logged: List of [Text];
        Message: Text;
        WouldPost: Boolean;
    begin
        BindSubscription(Capture);
        GenJnlPostPreview.SetContext(Subscriber, RecVar);
        ClearLastError();
        if GenJnlPostPreview.Run() then; // always false: codeunit 19 ends every run with an error
        UnbindSubscription(Capture);

        // IsSuccess compares with codeunit 19's own preview-mode text, so it holds in any language.
        WouldPost := GenJnlPostPreview.IsSuccess();
        if not WouldPost then begin
            if Capture.GetPostingError() <> '' then
                Errors.Add(Capture.GetPostingError());
            Logged := Capture.GetLoggedErrors();
            foreach Message in Logged do
                if Message <> Capture.GetPostingError() then
                    Errors.Add(Message);
        end;

        GenJnlPostPreview.GetPreviewHandler(Handler);
        Handler.FillDocumentEntry(TempDocumentEntry);
        if TempDocumentEntry.FindSet() then
            repeat
                Entries.Add(DescribeEntries(Handler, TempDocumentEntry."Table ID", TempDocumentEntry."No. of Records"));
            until TempDocumentEntry.Next() = 0;
        GLAccounts := SummarizeGLAccounts(Handler);

        Result.Add('preview', true);
        Result.Add('wouldPost', WouldPost);
        Result.Add('errors', Errors);
        Result.Add('entries', Entries);
        Result.Add('glAccounts', GLAccounts);
    end;

    // Count per ledger, plus the amounts held in normal fields. Cust./Vendor Ledger Entry Amount is a
    // FlowField over the detailed entries, which a temporary record cannot sum, so those come from the
    // detailed tables.
    local procedure DescribeEntries(Handler: Codeunit "Posting Preview Event Handler"; TableId: Integer; RecordCount: Integer) Entry: JsonObject
    var
        GLEntry: Record "G/L Entry";
        VATEntry: Record "VAT Entry";
        DtldCustLedgEntry: Record "Detailed Cust. Ledg. Entry";
        DtldVendLedgEntry: Record "Detailed Vendor Ledg. Entry";
        ItemLedgerEntry: Record "Item Ledger Entry";
        ValueEntry: Record "Value Entry";
        BankAccLedgerEntry: Record "Bank Account Ledger Entry";
        RecRef: RecordRef;
    begin
        Handler.GetEntries(TableId, RecRef);
        Entry.Add('table', RecRef.Name);
        Entry.Add('tableId', TableId);
        Entry.Add('count', RecordCount);
        case TableId of
            Database::"G/L Entry":
                begin
                    Entry.Add('debit', SumOf(RecRef, GLEntry.FieldNo("Debit Amount")));
                    Entry.Add('credit', SumOf(RecRef, GLEntry.FieldNo("Credit Amount")));
                end;
            Database::"VAT Entry":
                begin
                    Entry.Add('base', SumOf(RecRef, VATEntry.FieldNo(Base)));
                    Entry.Add('amount', SumOf(RecRef, VATEntry.FieldNo(Amount)));
                end;
            Database::"Detailed Cust. Ledg. Entry":
                Entry.Add('amount', SumOf(RecRef, DtldCustLedgEntry.FieldNo(Amount)));
            Database::"Detailed Vendor Ledg. Entry":
                Entry.Add('amount', SumOf(RecRef, DtldVendLedgEntry.FieldNo(Amount)));
            Database::"Item Ledger Entry":
                Entry.Add('quantity', SumOf(RecRef, ItemLedgerEntry.FieldNo(Quantity)));
            Database::"Value Entry":
                begin
                    Entry.Add('costAmount', SumOf(RecRef, ValueEntry.FieldNo("Cost Amount (Actual)")));
                    Entry.Add('salesAmount', SumOf(RecRef, ValueEntry.FieldNo("Sales Amount (Actual)")));
                end;
            Database::"Bank Account Ledger Entry":
                Entry.Add('amount', SumOf(RecRef, BankAccLedgerEntry.FieldNo(Amount)));
        end;
    end;

    // Debit and credit per G/L account, in account order: which accounts the posting would hit.
    local procedure SummarizeGLAccounts(Handler: Codeunit "Posting Preview Event Handler") Accounts: JsonArray
    var
        GLEntry: Record "G/L Entry";
        RecRef: RecordRef;
        Debit, Credit : Dictionary of [Code[20], Decimal];
        AccountNos: List of [Code[20]];
        AccountNo: Code[20];
        Account: JsonObject;
        Value: Decimal;
    begin
        Handler.GetEntries(Database::"G/L Entry", RecRef);
        if not RecRef.FindSet() then
            exit;
        repeat
            AccountNo := RecRef.Field(GLEntry.FieldNo("G/L Account No.")).Value();
            if not AccountNos.Contains(AccountNo) then begin
                AccountNos.Add(AccountNo);
                Debit.Add(AccountNo, 0);
                Credit.Add(AccountNo, 0);
            end;
            Value := RecRef.Field(GLEntry.FieldNo("Debit Amount")).Value();
            Debit.Set(AccountNo, Debit.Get(AccountNo) + Value);
            Value := RecRef.Field(GLEntry.FieldNo("Credit Amount")).Value();
            Credit.Set(AccountNo, Credit.Get(AccountNo) + Value);
        until RecRef.Next() = 0;
        SortCodes(AccountNos);
        foreach AccountNo in AccountNos do begin
            Clear(Account);
            Account.Add('no', AccountNo);
            Account.Add('debit', Debit.Get(AccountNo));
            Account.Add('credit', Credit.Get(AccountNo));
            Accounts.Add(Account);
        end;
    end;

    local procedure SumOf(var RecRef: RecordRef; FieldNo: Integer) Total: Decimal
    var
        Value: Decimal;
    begin
        if not RecRef.FindSet() then
            exit;
        repeat
            Value := RecRef.Field(FieldNo).Value();
            Total += Value;
        until RecRef.Next() = 0;
    end;

    // Insertion sort; a posting touches a handful of accounts. AL evaluates both sides of `and`, so the
    // bounds check and the comparison are nested, never combined.
    local procedure SortCodes(var Codes: List of [Code[20]])
    var
        I, J : Integer;
        Current: Code[20];
        Moving: Boolean;
    begin
        for I := 2 to Codes.Count() do begin
            Current := Codes.Get(I);
            J := I - 1;
            Moving := true;
            while Moving do
                if J < 1 then
                    Moving := false
                else
                    if Codes.Get(J) > Current then begin
                        Codes.Set(J + 1, Codes.Get(J));
                        J -= 1;
                    end else
                        Moving := false;
            Codes.Set(J + 1, Current);
        end;
    end;
}
