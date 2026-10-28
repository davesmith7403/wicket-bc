codeunit 94208 "Bcmag Act Preview Capture"
{
    // Manual subscriber bound by Bcmag Act Preview for the length of one posting preview. It
    //   - applies the caller's ship/receive/invoice selection: the Yes/No posting codeunits force their
    //     own flags in OnRunPreview (sales: ship+invoice, purchase: receive+invoice) and expose one hook
    //     each to change them;
    //   - hides the journal posting dialogs (a headless session cannot answer a Confirm);
    //   - captures the failure reason. Codeunit 19's OnRun ends with Error(''), which wipes
    //     GetLastErrorText before the caller sees it. OnAfterUnbindSubscription fires inside PreviewStart
    //     right after the posting run, while (a) the last error is still the posting error and (b)
    //     PreviewStart's own Error Message Handler is still bound: checks that log through Error Message
    //     Management and stop with a silent error leave their reasons only there.
    EventSubscriberInstance = Manual;

    var
        PostingError: Text;
        LoggedErrors: List of [Text];
        SalesFlagsSet, PurchaseFlagsSet : Boolean;
        Ship, Invoice, Receive : Boolean;

    procedure SetSalesFlags(NewShip: Boolean; NewInvoice: Boolean; NewReceive: Boolean)
    begin
        Ship := NewShip;
        Invoice := NewInvoice;
        Receive := NewReceive;
        SalesFlagsSet := true;
    end;

    procedure SetPurchaseFlags(NewReceive: Boolean; NewInvoice: Boolean; NewShip: Boolean)
    begin
        Receive := NewReceive;
        Invoice := NewInvoice;
        Ship := NewShip;
        PurchaseFlagsSet := true;
    end;

    procedure GetPostingError(): Text
    begin
        exit(PostingError);
    end;

    procedure GetLoggedErrors(): List of [Text]
    begin
        exit(LoggedErrors);
    end;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"Sales-Post (Yes/No)", 'OnRunPreviewOnAfterSetPostingFlags', '', false, false)]
    local procedure ApplySalesFlags(var SalesHeader: Record "Sales Header")
    begin
        if not SalesFlagsSet then
            exit;
        SalesHeader.Ship := Ship;
        SalesHeader.Invoice := Invoice;
        SalesHeader.Receive := Receive;
    end;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"Purch.-Post (Yes/No)", 'OnRunPreviewOnBeforePurchPostRun', '', false, false)]
    local procedure ApplyPurchaseFlags(var PurchaseHeader: Record "Purchase Header")
    begin
        if not PurchaseFlagsSet then
            exit;
        PurchaseHeader.Receive := Receive;
        PurchaseHeader.Invoice := Invoice;
        PurchaseHeader.Ship := Ship;
    end;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"Gen. Jnl.-Post", 'OnBeforeCode', '', false, false)]
    local procedure HideGenJournalDialogs(var GenJournalLine: Record "Gen. Journal Line"; var HideDialog: Boolean)
    begin
        HideDialog := true;
    end;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"Item Jnl.-Post", 'OnBeforeCode', '', false, false)]
    local procedure HideItemJournalDialogs(var ItemJournalLine: Record "Item Journal Line"; var HideDialog: Boolean; var SuppressCommit: Boolean; var IsHandled: Boolean)
    begin
        HideDialog := true;
    end;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"Gen. Jnl.-Post Preview", 'OnAfterUnbindSubscription', '', false, false)]
    local procedure CaptureOnAfterUnbindSubscription()
    var
        TempErrorMessage: Record "Error Message" temporary;
        ErrorMessageMgt: Codeunit "Error Message Management";
    begin
        PostingError := GetLastErrorText();
        if ErrorMessageMgt.GetErrors(TempErrorMessage) then
            if TempErrorMessage.FindSet() then
                repeat
                    if (TempErrorMessage.Message <> '') and not LoggedErrors.Contains(TempErrorMessage.Message) then
                        LoggedErrors.Add(TempErrorMessage.Message);
                until TempErrorMessage.Next() = 0;
    end;
}
