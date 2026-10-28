codeunit 94218 "Bcmag Act Document Pdf"
{
    // Action wrapper for `document-pdf` (non-mutating, category render): the PDF a person would get from
    // the document's Print/Send action, rendered by the report the tenant's Report Selections (and the
    // customer's or vendor's document layouts) choose, through Base Application's Report Selections
    // GetPdfReportForCust / GetPdfReportForVend. Enrolled non-mutating, so it runs inside the action op's
    // forced rollback: a report that stamps No. Printed and commits leaves no trace.
    // args:   { document, systemId | no }
    //         document: salesQuote | salesOrder | salesInvoice | postedSalesInvoice | postedSalesCreditMemo |
    //         postedSalesShipment | purchaseQuote | purchaseOrder | postedPurchaseInvoice | postedPurchaseCreditMemo
    // result: { document, no, fileName, contentType: "application/pdf", sizeBytes, base64 } — refused above 10 MB,
    //         the readBlob cap.

    var
        MaxPdfBytes: Integer;

    trigger OnRun()
    var
        ReportSelections: Record "Report Selections";
        Ctx: Codeunit "Bcmag Invoke Context";
        Helper: Codeunit "Bcmag Act Helper";
        TempBlob: Codeunit "Temp Blob";
        Base64Convert: Codeunit "Base64 Convert";
        RecRef: RecordRef;
        Args, Result : JsonObject;
        InStr: InStream;
        Kind, DocNo, PartyNo : Text;
        Usage: Enum "Report Selection Usage";
        TableId, DocTypeOrdinal, PartyFieldNo : Integer;
        IsVendor: Boolean;
        Size: Integer;
        FileNameTok: Label '%1-%2.pdf', Locked = true;
    begin
        MaxPdfBytes := 10 * 1024 * 1024;
        Args := Ctx.GetArgs();
        Kind := Helper.RequireText(Args, 'document');
        Describe(Kind, TableId, DocTypeOrdinal, Usage, PartyFieldNo, IsVendor);
        Locate(Args, Kind, TableId, DocTypeOrdinal, RecRef);
        DocNo := Format(RecRef.Field(NoFieldNo(TableId)).Value());
        PartyNo := Format(RecRef.Field(PartyFieldNo).Value());
        RecRef.SetRecFilter();

        if IsVendor then
            ReportSelections.GetPdfReportForVend(TempBlob, Usage, RecRef, CopyStr(PartyNo, 1, 20))
        else
            ReportSelections.GetPdfReportForCust(TempBlob, Usage, RecRef, CopyStr(PartyNo, 1, 20));

        Size := TempBlob.Length();
        if Size = 0 then
            Error('the report for %1 %2 produced no PDF; check Report Selections for this document', Kind, DocNo);
        if Size > MaxPdfBytes then
            Error('the PDF for %1 %2 is %3 bytes, above the %4-byte limit', Kind, DocNo, Size, MaxPdfBytes);
        TempBlob.CreateInStream(InStr);

        Result.Add('document', Kind);
        Result.Add('no', DocNo);
        Result.Add('fileName', StrSubstNo(FileNameTok, Kind, DelChr(DocNo, '=', '/\:*?"<>|')));
        Result.Add('contentType', 'application/pdf');
        Result.Add('sizeBytes', Size);
        Result.Add('base64', Base64Convert.ToBase64(InStr));
        Ctx.SetResult(Result);
    end;

    // The document kind → its table, the header document type (-1 for posted tables), the report usage,
    // and whose document layouts apply (the bill-to customer, or the buy-from vendor).
    local procedure Describe(Kind: Text; var TableId: Integer; var DocTypeOrdinal: Integer; var Usage: Enum "Report Selection Usage"; var PartyFieldNo: Integer; var IsVendor: Boolean)
    var
        SalesHeader: Record "Sales Header";
        SalesInvHeader: Record "Sales Invoice Header";
        SalesCrMemoHeader: Record "Sales Cr.Memo Header";
        SalesShptHeader: Record "Sales Shipment Header";
        PurchHeader: Record "Purchase Header";
        PurchInvHeader: Record "Purch. Inv. Header";
        PurchCrMemoHdr: Record "Purch. Cr. Memo Hdr.";
    begin
        DocTypeOrdinal := -1;
        IsVendor := false;
        case Kind of
            'salesQuote', 'salesOrder', 'salesInvoice':
                begin
                    TableId := Database::"Sales Header";
                    PartyFieldNo := SalesHeader.FieldNo("Bill-to Customer No.");
                    case Kind of
                        'salesQuote':
                            begin
                                DocTypeOrdinal := SalesHeader."Document Type"::Quote.AsInteger();
                                Usage := Usage::"S.Quote";
                            end;
                        'salesOrder':
                            begin
                                DocTypeOrdinal := SalesHeader."Document Type"::Order.AsInteger();
                                Usage := Usage::"S.Order";
                            end;
                        'salesInvoice':
                            begin
                                DocTypeOrdinal := SalesHeader."Document Type"::Invoice.AsInteger();
                                Usage := Usage::"S.Invoice Draft";
                            end;
                    end;
                end;
            'postedSalesInvoice':
                begin
                    TableId := Database::"Sales Invoice Header";
                    PartyFieldNo := SalesInvHeader.FieldNo("Bill-to Customer No.");
                    Usage := Usage::"S.Invoice";
                end;
            'postedSalesCreditMemo':
                begin
                    TableId := Database::"Sales Cr.Memo Header";
                    PartyFieldNo := SalesCrMemoHeader.FieldNo("Bill-to Customer No.");
                    Usage := Usage::"S.Cr.Memo";
                end;
            'postedSalesShipment':
                begin
                    TableId := Database::"Sales Shipment Header";
                    PartyFieldNo := SalesShptHeader.FieldNo("Bill-to Customer No.");
                    Usage := Usage::"S.Shipment";
                end;
            'purchaseQuote', 'purchaseOrder':
                begin
                    TableId := Database::"Purchase Header";
                    PartyFieldNo := PurchHeader.FieldNo("Buy-from Vendor No.");
                    IsVendor := true;
                    if Kind = 'purchaseQuote' then begin
                        DocTypeOrdinal := PurchHeader."Document Type"::Quote.AsInteger();
                        Usage := Usage::"P.Quote";
                    end else begin
                        DocTypeOrdinal := PurchHeader."Document Type"::Order.AsInteger();
                        Usage := Usage::"P.Order";
                    end;
                end;
            'postedPurchaseInvoice':
                begin
                    TableId := Database::"Purch. Inv. Header";
                    PartyFieldNo := PurchInvHeader.FieldNo("Buy-from Vendor No.");
                    IsVendor := true;
                    Usage := Usage::"P.Invoice";
                end;
            'postedPurchaseCreditMemo':
                begin
                    TableId := Database::"Purch. Cr. Memo Hdr.";
                    PartyFieldNo := PurchCrMemoHdr.FieldNo("Buy-from Vendor No.");
                    IsVendor := true;
                    Usage := Usage::"P.Cr.Memo";
                end;
            else
                Error('unknown document "%1" (use salesQuote, salesOrder, salesInvoice, postedSalesInvoice, postedSalesCreditMemo, postedSalesShipment, purchaseQuote, purchaseOrder, postedPurchaseInvoice or postedPurchaseCreditMemo)', Kind);
        end;
    end;

    // By systemId (a query row's @systemId, or target.systemId), else by no. A header found by systemId
    // must be of the kind's document type, so a quote's id cannot print an order.
    local procedure Locate(Args: JsonObject; Kind: Text; TableId: Integer; DocTypeOrdinal: Integer; var RecRef: RecordRef)
    var
        SalesHeader: Record "Sales Header";
        PurchHeader: Record "Purchase Header";
        Helper: Codeunit "Bcmag Act Helper";
        SysIdTxt, NoTxt : Text;
        SysId: Guid;
    begin
        RecRef.Open(TableId);
        if Helper.GetText(Args, 'systemId', SysIdTxt) then begin
            if not Evaluate(SysId, SysIdTxt) then
                Error('args.systemId "%1" is not a valid GUID', SysIdTxt);
            if not RecRef.GetBySystemId(SysId) then
                Error('no %1 with systemId %2', Kind, SysIdTxt);
            if DocTypeOrdinal <> -1 then
                if HeaderDocTypeOrdinal(RecRef) <> DocTypeOrdinal then
                    Error('systemId %1 is not a %2', SysIdTxt, Kind);
            exit;
        end;
        if not Helper.GetText(Args, 'no', NoTxt) then
            Error('provide args.systemId or args.no');
        if StrLen(NoTxt) > 20 then
            Error('args.no must be at most 20 characters');
        case TableId of
            Database::"Sales Header":
                begin
                    if not SalesHeader.Get(Enum::"Sales Document Type".FromInteger(DocTypeOrdinal), NoTxt) then
                        Error('no %1 "%2"', Kind, NoTxt);
                    RecRef.GetTable(SalesHeader);
                end;
            Database::"Purchase Header":
                begin
                    if not PurchHeader.Get(Enum::"Purchase Document Type".FromInteger(DocTypeOrdinal), NoTxt) then
                        Error('no %1 "%2"', Kind, NoTxt);
                    RecRef.GetTable(PurchHeader);
                end;
            else begin
                RecRef.Field(NoFieldNo(TableId)).SetRange(NoTxt);
                if not RecRef.FindFirst() then
                    Error('no %1 "%2"', Kind, NoTxt);
            end;
        end;
    end;

    local procedure HeaderDocTypeOrdinal(var RecRef: RecordRef): Integer
    var
        SalesHeader: Record "Sales Header";
        PurchHeader: Record "Purchase Header";
    begin
        case RecRef.Number of
            Database::"Sales Header":
                begin
                    RecRef.SetTable(SalesHeader);
                    exit(SalesHeader."Document Type".AsInteger());
                end;
            Database::"Purchase Header":
                begin
                    RecRef.SetTable(PurchHeader);
                    exit(PurchHeader."Document Type".AsInteger());
                end;
        end;
        exit(-1);
    end;

    // "No." is field 3 on every header table served here; resolved through a typed record so a renumbered
    // field would not compile rather than silently read another column.
    local procedure NoFieldNo(TableId: Integer): Integer
    var
        SalesHeader: Record "Sales Header";
        SalesInvHeader: Record "Sales Invoice Header";
        SalesCrMemoHeader: Record "Sales Cr.Memo Header";
        SalesShptHeader: Record "Sales Shipment Header";
        PurchHeader: Record "Purchase Header";
        PurchInvHeader: Record "Purch. Inv. Header";
        PurchCrMemoHdr: Record "Purch. Cr. Memo Hdr.";
    begin
        case TableId of
            Database::"Sales Header":
                exit(SalesHeader.FieldNo("No."));
            Database::"Sales Invoice Header":
                exit(SalesInvHeader.FieldNo("No."));
            Database::"Sales Cr.Memo Header":
                exit(SalesCrMemoHeader.FieldNo("No."));
            Database::"Sales Shipment Header":
                exit(SalesShptHeader.FieldNo("No."));
            Database::"Purchase Header":
                exit(PurchHeader.FieldNo("No."));
            Database::"Purch. Inv. Header":
                exit(PurchInvHeader.FieldNo("No."));
            Database::"Purch. Cr. Memo Hdr.":
                exit(PurchCrMemoHdr.FieldNo("No."));
        end;
    end;
}
