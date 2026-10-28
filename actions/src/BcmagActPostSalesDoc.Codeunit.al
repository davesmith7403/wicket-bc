codeunit 94200 "Bcmag Act Post Sales Doc"
{
    // Action wrapper: post a Sales Header through the non-interactive Sales-Post (80), reachable via
    // Wicket `invoke { codeunitId: 94200, procedure: "PostSalesDocument", args: {...} }`. This lives in
    // a Base-App-dependent companion because a System-Application-only extension cannot name
    // Record "Sales Header" / Codeunit "Sales-Post". Errors bubble as AL errors, which Wicket's invoke
    // op turns into a 422 with the message. NOTE: Sales-Post COMMITs on success — a posted document is
    // durable and is NOT covered by any outer Wicket rollback.
    //
    // args:  { systemId? , documentType? , no? , ship? , invoice? , receive? , preview? }
    //        Address the header by SystemId (preferred) OR documentType + no.
    //        Ship/Invoice/Receive default to ship+invoice=true (a normal sales post). For a Return Order
    //        the default is receive+invoice (Sales-Post forces Ship off on a return order, so the old
    //        ship default meant "invoice without receiving"). They are transient posting selections set
    //        on the record before posting; Sales-Post itself overrides them for Invoice / Credit Memo.
    // result:{ posted:true, sourceDocumentType, sourceNo, postedInvoiceNo?, postedShipmentNo?, postedReturnReceiptNo?,
    //          postCommitWarning?, postCommitEvidence? }
    // preview: with args.preview = true (the action op sets it for data.preview = true and runs the call in
    //        its forced rollback) nothing is posted: the result is Bcmag Act Preview's { preview: true,
    //        wouldPost, errors, entries, glAccounts } plus sourceDocumentType and sourceNo, with the same posting selection applied.
    //        A posted-number member appears only when its stamp changed in THIS call — absence means
    //        that phase did not happen here (the header keeps stale stamps from earlier partial posts).
    //        postedInvoiceNo is Sales-Post's "Last Posting No.": for a Credit Memo / Return Order it is the
    //        posted CREDIT MEMO number (the member name is kept for compatibility).
    //
    // Post-commit failures: Sales-Post COMMITs the posted document and THEN runs more code (analysis
    // view refresh, OnAfterPostSalesDoc subscribers). An error there makes Codeunit.Run return false
    // although the document IS posted. Reporting that as "posting failed" (a final 422, cached under the
    // idempotency key) invites the caller to post again. So on failure the wrapper re-reads the database:
    // if the header's Last ... No. stamps moved, or (header deleted after a full post) a posted document
    // for this source was created during this call, it answers posted:true with postCommitWarning (the
    // error text) and postCommitEvidence (what proved it). Only without such evidence is it a failure.

    trigger OnRun()
    var
        Ctx: Codeunit "Bcmag Invoke Context";
        Helper: Codeunit "Bcmag Act Helper";
        Preview: Codeunit "Bcmag Act Preview";
        SalesHeader: Record "Sales Header";
        Args, Result: JsonObject;
        PrevPostingNo, PrevShippingNo, PrevReturnReceiptNo: Code[20];
        DocType: Enum "Sales Document Type";
        DocNo: Code[20];
        StartedAt: DateTime;
        PostingError, Evidence: Text;
        PostingFailedErr: Label 'posting sales %1 %2 failed: %3', Comment = '%1 = document type, %2 = document no., %3 = posting error text';
    begin
        Args := Ctx.GetArgs();
        ResolveHeader(Args, Helper, SalesHeader);
        ApplyPostingSelection(Args, Helper, SalesHeader);
        DocType := SalesHeader."Document Type";
        DocNo := SalesHeader."No.";

        if Helper.GetBool(Args, 'preview', false) then begin
            Result := Preview.PreviewSales(SalesHeader);
            Result.Add('sourceDocumentType', DocTypeName(DocType));
            Result.Add('sourceNo', DocNo);
            Ctx.SetResult(Result);
            exit;
        end;

        // "Last ... No." are persisted header stamps that posting overwrites but never clears, so on a
        // partially-posted order they still hold numbers from PREVIOUS posts. Capture the pre-post values
        // so BuildResult can emit only the stamps this call actually changed.
        PrevPostingNo := SalesHeader."Last Posting No.";
        PrevShippingNo := SalesHeader."Last Shipping No.";
        PrevReturnReceiptNo := SalesHeader."Last Return Receipt No.";

        // Run the non-interactive poster (80). NOTE: 80 COMMITs internally as it posts, so a failure is
        // NOT rolled back by this Boolean form — a partial ship/receive may already be durable. Re-raise
        // so the invoke op reports a 422; ClearLastError first, and compose the message so it still
        // identifies the document when a posting abort path leaves GetLastErrorText empty.
        StartedAt := CurrentDateTime();
        ClearLastError();
        if not Codeunit.Run(Codeunit::"Sales-Post", SalesHeader) then begin
            PostingError := GetLastErrorText();
            if not PostedDespiteError(DocType, DocNo, PrevPostingNo, PrevShippingNo, PrevReturnReceiptNo, StartedAt, Result, Evidence) then
                Error(PostingFailedErr, DocTypeName(DocType), DocNo, PostingError);
            Result.Add('postCommitWarning', PostingError);
            Result.Add('postCommitEvidence', Evidence);
            Ctx.SetResult(Result);
            exit;
        end;

        BuildResult(SalesHeader, PrevPostingNo, PrevShippingNo, PrevReturnReceiptNo, Result);
        Ctx.SetResult(Result);
    end;

    // After Codeunit.Run returned false: did the posting commit anyway? The in-memory header is not
    // trustworthy after a failed run, so everything is re-read from the database.
    //   header still there (partial post, or the error came before deletion) → its Last ... No. stamps
    //     moved away from the pre-post values: exactly what UpdateLastPostingNos writes before commit;
    //   header gone (fully posted and deleted before the commit) → a posted document that references
    //     this source and was created since the call started.
    local procedure PostedDespiteError(DocType: Enum "Sales Document Type"; DocNo: Code[20]; PrevPostingNo: Code[20]; PrevShippingNo: Code[20]; PrevReturnReceiptNo: Code[20]; StartedAt: DateTime; var Result: JsonObject; var Evidence: Text): Boolean
    var
        SalesHeader: Record "Sales Header";
        SalesInvHeader: Record "Sales Invoice Header";
        SalesCrMemoHeader: Record "Sales Cr.Memo Header";
        SalesShptHeader: Record "Sales Shipment Header";
        ReturnRcptHeader: Record "Return Receipt Header";
        Since: DateTime;
        Found: Boolean;
    begin
        Clear(Result);
        if SalesHeader.Get(DocType, DocNo) then begin
            BuildResult(SalesHeader, PrevPostingNo, PrevShippingNo, PrevReturnReceiptNo, Result);
            Evidence := 'the source header''s Last Posting/Shipping/Return Receipt No. changed during this call';
            exit(Result.Contains('postedInvoiceNo') or Result.Contains('postedShipmentNo') or Result.Contains('postedReturnReceiptNo'));
        end;

        // SQL Server rounds DateTime on write; a one-second margin keeps a document created at the very
        // start of the call inside the window (another post of the SAME source that close is not plausible).
        Since := StartedAt - 1000;
        Result.Add('posted', true);
        Result.Add('sourceDocumentType', DocTypeName(DocType));
        Result.Add('sourceNo', DocNo);
        case DocType of
            DocType::Order, DocType::Invoice:
                begin
                    if DocType = DocType::Order then
                        SalesInvHeader.SetRange("Order No.", DocNo)
                    else
                        SalesInvHeader.SetRange("Pre-Assigned No.", DocNo);
                    SalesInvHeader.SetFilter(SystemCreatedAt, '>=%1', Since);
                    if SalesInvHeader.FindLast() then begin
                        Result.Add('postedInvoiceNo', SalesInvHeader."No.");
                        Found := true;
                    end;
                    if DocType = DocType::Order then begin
                        SalesShptHeader.SetRange("Order No.", DocNo);
                        SalesShptHeader.SetFilter(SystemCreatedAt, '>=%1', Since);
                        if SalesShptHeader.FindLast() then begin
                            Result.Add('postedShipmentNo', SalesShptHeader."No.");
                            Found := true;
                        end;
                    end;
                end;
            DocType::"Credit Memo", DocType::"Return Order":
                begin
                    if DocType = DocType::"Return Order" then
                        SalesCrMemoHeader.SetRange("Return Order No.", DocNo)
                    else
                        SalesCrMemoHeader.SetRange("Pre-Assigned No.", DocNo);
                    SalesCrMemoHeader.SetFilter(SystemCreatedAt, '>=%1', Since);
                    if SalesCrMemoHeader.FindLast() then begin
                        Result.Add('postedInvoiceNo', SalesCrMemoHeader."No.");
                        Found := true;
                    end;
                    if DocType = DocType::"Return Order" then begin
                        ReturnRcptHeader.SetRange("Return Order No.", DocNo);
                        ReturnRcptHeader.SetFilter(SystemCreatedAt, '>=%1', Since);
                        if ReturnRcptHeader.FindLast() then begin
                            Result.Add('postedReturnReceiptNo', ReturnRcptHeader."No.");
                            Found := true;
                        end;
                    end;
                end;
        end;
        Evidence := 'the source header was deleted by posting and a posted document for it was created during this call';
        exit(Found);
    end;

    // Locate the header. SystemId is the stable, opaque handle a caller already holds from a query
    // (@systemId); documentType + no is the explicit fallback. A miss is an error → 404-ish 422.
    local procedure ResolveHeader(Args: JsonObject; Helper: Codeunit "Bcmag Act Helper"; var SalesHeader: Record "Sales Header")
    var
        SysIdTxt, NoTxt, DocTypeTxt: Text;
        SysId: Guid;
        DocType: Enum "Sales Document Type";
    begin
        if Helper.GetText(Args, 'systemId', SysIdTxt) then begin
            if not Evaluate(SysId, SysIdTxt) then
                Error('args.systemId "%1" is not a valid GUID', SysIdTxt);
            if not SalesHeader.GetBySystemId(SysId) then
                Error('no sales header with systemId %1', SysIdTxt);
            exit;
        end;

        if Helper.GetText(Args, 'no', NoTxt) then begin
            // Never default the type on a mutating action: "no." series can collide across document
            // types, so an implicit Order could silently post the wrong document.
            if not Helper.GetText(Args, 'documentType', DocTypeTxt) then
                Error('documentType is required when addressing by no.');
            DocType := ParseDocType(DocTypeTxt);
            // Get on a Code[20] key raises a raw overflow error for longer input.
            if StrLen(NoTxt) > MaxStrLen(SalesHeader."No.") then
                Error('args.no must be at most %1 characters', MaxStrLen(SalesHeader."No."));
            if not SalesHeader.Get(DocType, NoTxt) then
                Error('no sales header %1 "%2"', Format(DocType), NoTxt);
            exit;
        end;

        Error('provide args.systemId, or args.documentType + args.no');
    end;

    local procedure ApplyPostingSelection(Args: JsonObject; Helper: Codeunit "Bcmag Act Helper"; var SalesHeader: Record "Sales Header")
    var
        IsReturn: Boolean;
    begin
        // Defaults follow the document's natural direction: a return order RECEIVES (Sales-Post forces
        // Ship off for it), everything else ships. Explicit args always win.
        IsReturn := SalesHeader."Document Type" = SalesHeader."Document Type"::"Return Order";
        SalesHeader.Ship := Helper.GetBool(Args, 'ship', not IsReturn);
        SalesHeader.Invoice := Helper.GetBool(Args, 'invoice', true);
        SalesHeader.Receive := Helper.GetBool(Args, 'receive', IsReturn);
    end;

    // After a successful post the source header row is gone, but the in-memory record (passed by
    // reference into Sales-Post) still carries the "Last ... No." stamps written during posting.
    // Each posted-number member is emitted only when the stamp is non-empty AND changed by THIS call
    // (posting never clears them, so an unchanged stamp is a leftover from an earlier partial post).
    local procedure BuildResult(var SalesHeader: Record "Sales Header"; PrevPostingNo: Code[20]; PrevShippingNo: Code[20]; PrevReturnReceiptNo: Code[20]; var Result: JsonObject)
    begin
        Result.Add('posted', true);
        Result.Add('sourceDocumentType', DocTypeName(SalesHeader."Document Type"));
        Result.Add('sourceNo', SalesHeader."No.");
        if (SalesHeader."Last Posting No." <> '') and (SalesHeader."Last Posting No." <> PrevPostingNo) then
            Result.Add('postedInvoiceNo', SalesHeader."Last Posting No.");
        if (SalesHeader."Last Shipping No." <> '') and (SalesHeader."Last Shipping No." <> PrevShippingNo) then
            Result.Add('postedShipmentNo', SalesHeader."Last Shipping No.");
        if (SalesHeader."Last Return Receipt No." <> '') and (SalesHeader."Last Return Receipt No." <> PrevReturnReceiptNo) then
            Result.Add('postedReturnReceiptNo', SalesHeader."Last Return Receipt No.");
    end;

    // Invariant enum names — never Format() an enum into a machine identifier (locale-dependent).
    local procedure ParseDocType(Input: Text): Enum "Sales Document Type"
    begin
        case LowerCase(DelChr(Input, '<>', ' ')) of
            'quote':
                exit(Enum::"Sales Document Type"::Quote);
            'order':
                exit(Enum::"Sales Document Type"::Order);
            'invoice':
                exit(Enum::"Sales Document Type"::Invoice);
            'creditmemo', 'credit memo':
                exit(Enum::"Sales Document Type"::"Credit Memo");
            'blanketorder', 'blanket order':
                exit(Enum::"Sales Document Type"::"Blanket Order");
            'returnorder', 'return order':
                exit(Enum::"Sales Document Type"::"Return Order");
        end;
        Error('unknown documentType "%1" (use Quote/Order/Invoice/Credit Memo/Blanket Order/Return Order)', Input);
    end;

    local procedure DocTypeName(DocType: Enum "Sales Document Type"): Text
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
