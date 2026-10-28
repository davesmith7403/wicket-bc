codeunit 94202 "Bcmag Act Post Purchase Doc"
{
    // Action wrapper: post a Purchase Header through the non-interactive Purch.-Post (90).
    // invoke { codeunitId: 94202, procedure: "PostPurchaseDocument", args: {...} }
    // args:  { systemId? , documentType? , no? , receive? , invoice? , ship? , preview? }
    //        Receive/Invoice default true (a normal purchase post). For a Return Order the default is
    //        ship+invoice (Purch.-Post forces Receive off on a return order). Explicit args always win.
    // result:{ posted:true, sourceDocumentType, sourceNo, postedInvoiceNo?, postedReceiptNo?, postedReturnShipmentNo?,
    //          postCommitWarning?, postCommitEvidence? }
    // preview: with args.preview = true (the action op sets it for data.preview = true and runs the call in
    //        its forced rollback) nothing is posted: the result is Bcmag Act Preview's { preview: true,
    //        wouldPost, errors, entries, glAccounts } plus sourceDocumentType and sourceNo, with the same posting selection applied.
    //        A posted-number member appears only when its "Last ... No." stamp changed in THIS call —
    //        absence means that phase did not happen here (stamps persist from earlier partial posts).
    //        postedInvoiceNo is "Last Posting No.": for a Credit Memo / Return Order it is the posted
    //        CREDIT MEMO number (member name kept for compatibility).
    // Purch.-Post COMMITs on success — the posted document is durable, outside any Wicket rollback. It
    // also commits BEFORE its analysis-view refresh; an error after that commit is reported as
    // posted:true + postCommitWarning when the database proves the posting (see Bcmag Act Post Sales Doc).

    trigger OnRun()
    var
        Ctx: Codeunit "Bcmag Invoke Context";
        Helper: Codeunit "Bcmag Act Helper";
        Preview: Codeunit "Bcmag Act Preview";
        PurchHeader: Record "Purchase Header";
        Args, Result: JsonObject;
        PrevPostingNo, PrevReceivingNo, PrevReturnShipmentNo: Code[20];
        DocType: Enum "Purchase Document Type";
        DocNo: Code[20];
        StartedAt: DateTime;
        PostingError, Evidence: Text;
        IsReturn: Boolean;
        PostingFailedErr: Label 'posting purchase %1 %2 failed: %3', Comment = '%1 = document type, %2 = document no., %3 = posting error text';
    begin
        Args := Ctx.GetArgs();
        ResolveHeader(Args, Helper, PurchHeader);
        // A purchase return order SHIPS back (Purch.-Post forces Receive off for it).
        IsReturn := PurchHeader."Document Type" = PurchHeader."Document Type"::"Return Order";
        PurchHeader.Receive := Helper.GetBool(Args, 'receive', not IsReturn);
        PurchHeader.Invoice := Helper.GetBool(Args, 'invoice', true);
        PurchHeader.Ship := Helper.GetBool(Args, 'ship', IsReturn);
        DocType := PurchHeader."Document Type";
        DocNo := PurchHeader."No.";

        if Helper.GetBool(Args, 'preview', false) then begin
            Result := Preview.PreviewPurchase(PurchHeader);
            Result.Add('sourceDocumentType', DocTypeName(DocType));
            Result.Add('sourceNo', DocNo);
            Ctx.SetResult(Result);
            exit;
        end;

        // "Last ... No." are persisted stamps that posting overwrites but never clears; capture the
        // pre-post values so the result only reports numbers this call actually produced.
        PrevPostingNo := PurchHeader."Last Posting No.";
        PrevReceivingNo := PurchHeader."Last Receiving No.";
        PrevReturnShipmentNo := PurchHeader."Last Return Shipment No.";

        // ClearLastError first, and compose the message so it still identifies the document when a
        // posting abort path leaves GetLastErrorText empty.
        StartedAt := CurrentDateTime();
        ClearLastError();
        if not Codeunit.Run(Codeunit::"Purch.-Post", PurchHeader) then begin
            PostingError := GetLastErrorText();
            if not PostedDespiteError(DocType, DocNo, PrevPostingNo, PrevReceivingNo, PrevReturnShipmentNo, StartedAt, Result, Evidence) then
                Error(PostingFailedErr, DocTypeName(DocType), DocNo, PostingError);
            Result.Add('postCommitWarning', PostingError);
            Result.Add('postCommitEvidence', Evidence);
            Ctx.SetResult(Result);
            exit;
        end;

        BuildResult(PurchHeader, PrevPostingNo, PrevReceivingNo, PrevReturnShipmentNo, Result);
        Ctx.SetResult(Result);
    end;

    local procedure BuildResult(var PurchHeader: Record "Purchase Header"; PrevPostingNo: Code[20]; PrevReceivingNo: Code[20]; PrevReturnShipmentNo: Code[20]; var Result: JsonObject)
    begin
        Result.Add('posted', true);
        Result.Add('sourceDocumentType', DocTypeName(PurchHeader."Document Type"));
        Result.Add('sourceNo', PurchHeader."No.");
        if (PurchHeader."Last Posting No." <> '') and (PurchHeader."Last Posting No." <> PrevPostingNo) then
            Result.Add('postedInvoiceNo', PurchHeader."Last Posting No.");
        if (PurchHeader."Last Receiving No." <> '') and (PurchHeader."Last Receiving No." <> PrevReceivingNo) then
            Result.Add('postedReceiptNo', PurchHeader."Last Receiving No.");
        if (PurchHeader."Last Return Shipment No." <> '') and (PurchHeader."Last Return Shipment No." <> PrevReturnShipmentNo) then
            Result.Add('postedReturnShipmentNo', PurchHeader."Last Return Shipment No.");
    end;

    // Same evidence rules as Bcmag Act Post Sales Doc.PostedDespiteError, over the purchase tables.
    local procedure PostedDespiteError(DocType: Enum "Purchase Document Type"; DocNo: Code[20]; PrevPostingNo: Code[20]; PrevReceivingNo: Code[20]; PrevReturnShipmentNo: Code[20]; StartedAt: DateTime; var Result: JsonObject; var Evidence: Text): Boolean
    var
        PurchHeader: Record "Purchase Header";
        PurchInvHeader: Record "Purch. Inv. Header";
        PurchCrMemoHdr: Record "Purch. Cr. Memo Hdr.";
        PurchRcptHeader: Record "Purch. Rcpt. Header";
        ReturnShptHeader: Record "Return Shipment Header";
        Since: DateTime;
        Found: Boolean;
    begin
        Clear(Result);
        if PurchHeader.Get(DocType, DocNo) then begin
            BuildResult(PurchHeader, PrevPostingNo, PrevReceivingNo, PrevReturnShipmentNo, Result);
            Evidence := 'the source header''s Last Posting/Receiving/Return Shipment No. changed during this call';
            exit(Result.Contains('postedInvoiceNo') or Result.Contains('postedReceiptNo') or Result.Contains('postedReturnShipmentNo'));
        end;

        Since := StartedAt - 1000; // SQL DateTime rounding margin
        Result.Add('posted', true);
        Result.Add('sourceDocumentType', DocTypeName(DocType));
        Result.Add('sourceNo', DocNo);
        case DocType of
            DocType::Order, DocType::Invoice:
                begin
                    if DocType = DocType::Order then
                        PurchInvHeader.SetRange("Order No.", DocNo)
                    else
                        PurchInvHeader.SetRange("Pre-Assigned No.", DocNo);
                    PurchInvHeader.SetFilter(SystemCreatedAt, '>=%1', Since);
                    if PurchInvHeader.FindLast() then begin
                        Result.Add('postedInvoiceNo', PurchInvHeader."No.");
                        Found := true;
                    end;
                    if DocType = DocType::Order then begin
                        PurchRcptHeader.SetRange("Order No.", DocNo);
                        PurchRcptHeader.SetFilter(SystemCreatedAt, '>=%1', Since);
                        if PurchRcptHeader.FindLast() then begin
                            Result.Add('postedReceiptNo', PurchRcptHeader."No.");
                            Found := true;
                        end;
                    end;
                end;
            DocType::"Credit Memo", DocType::"Return Order":
                begin
                    if DocType = DocType::"Return Order" then
                        PurchCrMemoHdr.SetRange("Return Order No.", DocNo)
                    else
                        PurchCrMemoHdr.SetRange("Pre-Assigned No.", DocNo);
                    PurchCrMemoHdr.SetFilter(SystemCreatedAt, '>=%1', Since);
                    if PurchCrMemoHdr.FindLast() then begin
                        Result.Add('postedInvoiceNo', PurchCrMemoHdr."No.");
                        Found := true;
                    end;
                    if DocType = DocType::"Return Order" then begin
                        ReturnShptHeader.SetRange("Return Order No.", DocNo);
                        ReturnShptHeader.SetFilter(SystemCreatedAt, '>=%1', Since);
                        if ReturnShptHeader.FindLast() then begin
                            Result.Add('postedReturnShipmentNo', ReturnShptHeader."No.");
                            Found := true;
                        end;
                    end;
                end;
        end;
        Evidence := 'the source header was deleted by posting and a posted document for it was created during this call';
        exit(Found);
    end;

    local procedure ResolveHeader(Args: JsonObject; Helper: Codeunit "Bcmag Act Helper"; var PurchHeader: Record "Purchase Header")
    var
        SysIdTxt, NoTxt, DocTypeTxt: Text;
        SysId: Guid;
        DocType: Enum "Purchase Document Type";
    begin
        if Helper.GetText(Args, 'systemId', SysIdTxt) then begin
            if not Evaluate(SysId, SysIdTxt) then
                Error('args.systemId "%1" is not a valid GUID', SysIdTxt);
            if not PurchHeader.GetBySystemId(SysId) then
                Error('no purchase header with systemId %1', SysIdTxt);
            exit;
        end;
        if Helper.GetText(Args, 'no', NoTxt) then begin
            // Never default the type on a mutating action: "no." series can collide across document
            // types, so an implicit Order could silently post the wrong document.
            if not Helper.GetText(Args, 'documentType', DocTypeTxt) then
                Error('documentType is required when addressing by no.');
            DocType := ParseDocType(DocTypeTxt);
            // Get on a Code[20] key raises a raw overflow error for longer input.
            if StrLen(NoTxt) > MaxStrLen(PurchHeader."No.") then
                Error('args.no must be at most %1 characters', MaxStrLen(PurchHeader."No."));
            if not PurchHeader.Get(DocType, NoTxt) then
                Error('no purchase header %1 "%2"', Format(DocType), NoTxt);
            exit;
        end;
        Error('provide args.systemId, or args.documentType + args.no');
    end;

    local procedure ParseDocType(Input: Text): Enum "Purchase Document Type"
    begin
        case LowerCase(DelChr(Input, '<>', ' ')) of
            'quote':
                exit(Enum::"Purchase Document Type"::Quote);
            'order':
                exit(Enum::"Purchase Document Type"::Order);
            'invoice':
                exit(Enum::"Purchase Document Type"::Invoice);
            'creditmemo', 'credit memo':
                exit(Enum::"Purchase Document Type"::"Credit Memo");
            'blanketorder', 'blanket order':
                exit(Enum::"Purchase Document Type"::"Blanket Order");
            'returnorder', 'return order':
                exit(Enum::"Purchase Document Type"::"Return Order");
        end;
        Error('unknown documentType "%1" (use Quote/Order/Invoice/Credit Memo/Blanket Order/Return Order)', Input);
    end;

    local procedure DocTypeName(DocType: Enum "Purchase Document Type"): Text
    begin
        case DocType of
            DocType::Quote:
                exit('Quote');
            DocType::Order:
                exit('Order');
            DocType::Invoice:
                exit('Invoice');
            DocType::"Credit Memo":
                exit('Credit Memo');
            DocType::"Blanket Order":
                exit('Blanket Order');
            DocType::"Return Order":
                exit('Return Order');
        end;
        // Future enum extension values: return the invariant ordinal, never Format(DocType)
        // (that yields a locale-dependent caption).
        exit(Format(DocType.AsInteger()));
    end;
}
