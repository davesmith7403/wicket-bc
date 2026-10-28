codeunit 94350 "Bcmag Act Test Helper"
{
    // Fixtures for the Wicket Actions behavioural tests: configure the core's Setup + Action Catalog so
    // the four posting actions are reachable, drive the core dispatcher's `action` operation, and build
    // real Base Application documents/journals from whatever the company's demo data offers (customer,
    // vendor, G/L accounts, item) — located by posting-setup completeness rather than by hard-coded
    // numbers, so the suite runs in any CRONUS localisation. Minimal copy of the core test helper's
    // envelope logic (the core TEST app cannot be a dependency).
    //
    // Everything a test writes — fixtures, setup changes, and the postings the wrappers COMMIT — is
    // rolled back by the test runner's codeunit isolation. Numbers still come from the company's No.
    // Series and batch/template names are generated per call, so reruns never collide.

    var
        LibraryAssert: Codeunit "Library Assert";
        TemplateNameTok: Label 'BCMAGACT', Locked = true;

    // ---- setup ---------------------------------------------------------------------------------------

    // Open mode, keyless actions allowed, not read-only, the four posting actions enabled with preview
    // unsupported (as enrolled), and posting-date windows cleared so WorkDate() is postable.
    procedure Initialize()
    var
        Setup: Record "Bcmag Setup";
        GLSetup: Record "General Ledger Setup";
        UserSetup: Record "User Setup";
        Install: Codeunit "Bcmag Act Install";
    begin
        Setup.GetSingleton();
        Setup.Mode := Setup.Mode::Open;
        Setup."Allow Invoke In Open Mode" := false;
        Setup."Require ETag On Writes" := false;
        Setup."Read-Only Mode" := false;
        Setup."Field Policy Mode" := Setup."Field Policy Mode"::AllFields;
        Setup."Require Key For Actions" := false;
        Setup.Modify(true);

        // The catalog as the installed companion defines it (category, flags, schema), then every verb on.
        Install.RefreshAll();
        EnableAction('post-sales', Codeunit::"Bcmag Act Post Sales Doc");
        EnableAction('post-purchase', Codeunit::"Bcmag Act Post Purchase Doc");
        EnableAction('post-gen-journal', Codeunit::"Bcmag Act Post Gen Journal");
        EnableAction('post-item-journal', Codeunit::"Bcmag Act Post Item Journal");
        EnableAction('release-sales', Codeunit::"Bcmag Act Release Sales Doc");
        EnableAction('reopen-sales', Codeunit::"Bcmag Act Reopen Sales Doc");
        EnableAction('release-purchase', Codeunit::"Bcmag Act Release Purch Doc");
        EnableAction('reopen-purchase', Codeunit::"Bcmag Act Reopen Purch Doc");
        EnableAction('make-order-from-quote', Codeunit::"Bcmag Act Sales Quote To Order");
        EnableAction('make-invoice-from-quote', Codeunit::"Bcmag Act Sales Quote To Inv");
        EnableAction('make-purchase-order-from-quote', Codeunit::"Bcmag Act Purch Quote To Order");
        EnableAction('document-pdf', Codeunit::"Bcmag Act Document Pdf");
        EnableAction('item-availability', Codeunit::"Bcmag Act Item Availability");

        if GLSetup.Get() then begin
            GLSetup."Allow Posting From" := 0D;
            GLSetup."Allow Posting To" := 0D;
            GLSetup.Modify();
        end;
        if UserSetup.Get(UserId()) then begin
            UserSetup."Allow Posting From" := 0D;
            UserSetup."Allow Posting To" := 0D;
            UserSetup.Modify();
        end;
    end;

    // The companion enrols its rows DISABLED; a test opts in exactly like an admin would (Allow Run on).
    // A missing row (companion installed before a company existed) is enrolled here the same way.
    local procedure EnableAction(ActionCode: Code[50]; WrapperId: Integer)
    var
        Catalog: Record "Bcmag Action Catalog";
    begin
        if not Catalog.Get(ActionCode) then begin
            Catalog.Init();
            Catalog."Action Code" := ActionCode;
            Catalog."Wrapper Codeunit Id" := WrapperId;
            Catalog."Is Mutating" := true;
            Catalog.Insert();
        end;
        Catalog."Wrapper Codeunit Id" := WrapperId;
        Catalog."Allow Run" := true;
        Catalog.Modify();
    end;

    // ---- dispatcher ----------------------------------------------------------------------------------

    procedure ActionData(ActionCode: Text; TargetSystemId: Guid; Args: JsonObject) Data: JsonObject
    var
        Target: JsonObject;
    begin
        Data.Add('action', ActionCode);
        if not IsNullGuid(TargetSystemId) then begin
            Target.Add('systemId', GuidText(TargetSystemId));
            Data.Add('target', Target);
        end;
        Data.Add('args', Args);
    end;

    // Runs `action` through the real dispatcher. Commits first: the dispatcher's Op Runner boundary and
    // the wrappers' Codeunit.Run(Sales-Post …) need a clean transaction (fixtures leave one open).
    procedure RunAction(Data: JsonObject; IdemKey: Text; var Status: Integer) Response: JsonObject
    var
        Dispatcher: Codeunit "Bcmag Rpc Dispatcher";
        Body: JsonObject;
    begin
        Body.Add('id', GuidText(CreateGuid()));
        Body.Add('issuedAt', Format(CurrentDateTime(), 0, 9));
        Body.Add('origin', 'wicket.actions.test');
        Body.Add('data', Data);
        if IdemKey <> '' then
            Body.Add('idempotencyKey', IdemKey);
        Commit();
        Response := Dispatcher.RunEx('action', Body, '', Status);
    end;

    procedure NewIdemKey(): Text
    begin
        exit('act-' + GuidText(CreateGuid()));
    end;

    procedure GuidText(Value: Guid): Text
    begin
        exit(DelChr(LowerCase(Format(Value)), '<>', '{}'));
    end;

    // ---- response accessors --------------------------------------------------------------------------

    procedure ValueOf(Response: JsonObject) Value: JsonObject
    var
        Tok: JsonToken;
    begin
        if Response.Get('value', Tok) then
            if Tok.IsObject() then
                Value := Tok.AsObject();
    end;

    procedure Txt(Obj: JsonObject; Name: Text): Text
    var
        Tok: JsonToken;
    begin
        if Obj.Get(Name, Tok) then
            if Tok.IsValue() then
                if not Tok.AsValue().IsNull() then
                    exit(Tok.AsValue().AsText());
        exit('');
    end;

    procedure Int(Obj: JsonObject; Name: Text): Integer
    var
        Tok: JsonToken;
    begin
        if Obj.Get(Name, Tok) then
            if Tok.IsValue() then
                if not Tok.AsValue().IsNull() then
                    exit(Tok.AsValue().AsInteger());
        exit(0);
    end;

    procedure Bool(Obj: JsonObject; Name: Text): Boolean
    var
        Tok: JsonToken;
    begin
        if Obj.Get(Name, Tok) then
            if Tok.IsValue() then
                if not Tok.AsValue().IsNull() then
                    exit(Tok.AsValue().AsBoolean());
        exit(false);
    end;

    procedure Describe(Response: JsonObject) Json: Text
    begin
        Response.WriteTo(Json);
    end;

    procedure AssertOk(Status: Integer; Response: JsonObject; Context: Text)
    begin
        LibraryAssert.AreEqual(200, Status, Context + ': expected 200, got ' + Describe(Response));
        LibraryAssert.IsTrue(Bool(ValueOf(Response), 'posted'), Context + ': value.posted must be true: ' + Describe(Response));
        LibraryAssert.IsFalse(ValueOf(Response).Contains('postCommitWarning'), Context + ': a clean post carries no postCommitWarning: ' + Describe(Response));
    end;

    // A completed call that is not a post (a preview, a release): 200 and nothing else assumed.
    procedure AssertCompleted(Status: Integer; Response: JsonObject; Context: Text)
    begin
        LibraryAssert.AreEqual(200, Status, Context + ': expected 200, got ' + Describe(Response));
    end;

    procedure PreviewData(ActionCode: Text; TargetSystemId: Guid; Args: JsonObject) Data: JsonObject
    begin
        Data := ActionData(ActionCode, TargetSystemId, Args);
        Data.Add('preview', true);
    end;

    procedure Dec(Obj: JsonObject; Name: Text): Decimal
    var
        Tok: JsonToken;
    begin
        if Obj.Get(Name, Tok) then
            if Tok.IsValue() then
                if not Tok.AsValue().IsNull() then
                    exit(Tok.AsValue().AsDecimal());
        exit(0);
    end;

    // The preview entry for one ledger table, found by table id.
    procedure FindEntry(Value: JsonObject; TableId: Integer; var Entry: JsonObject): Boolean
    var
        Tok, Item : JsonToken;
    begin
        if not Value.Get('entries', Tok) then
            exit(false);
        foreach Item in Tok.AsArray() do
            if Int(Item.AsObject(), 'tableId') = TableId then begin
                Entry := Item.AsObject();
                exit(true);
            end;
        exit(false);
    end;

    procedure ArrayCount(Obj: JsonObject; Name: Text): Integer
    var
        Tok: JsonToken;
    begin
        if Obj.Get(Name, Tok) then
            if Tok.IsArray() then
                exit(Tok.AsArray().Count());
        exit(-1);
    end;

    procedure AssertProblem(Status: Integer; Response: JsonObject; ExpectedStatus: Integer; Slug: Text; Context: Text)
    begin
        LibraryAssert.AreEqual(ExpectedStatus, Status, Context + ': status; response ' + Describe(Response));
        LibraryAssert.IsTrue(StrPos(Txt(Response, 'type'), '/' + Slug) > 0, Context + ': expected type ' + Slug + ', got ' + Describe(Response));
    end;

    // ---- sales / purchase fixtures -------------------------------------------------------------------

    // A customer + direct-posting Sale G/L account whose General and VAT posting setups are complete, so
    // a G/L-account line posts without touching inventory.
    procedure FindSalesFixture(var CustNo: Code[20]; var GLAccNo: Code[20])
    var
        Customer: Record Customer;
        CustPostingGroup: Record "Customer Posting Group";
        GLAccount: Record "G/L Account";
        Scanned: Integer;
    begin
        Customer.SetRange(Blocked, Customer.Blocked::" ");
        Customer.SetRange("Privacy Blocked", false);
        Customer.SetRange("Currency Code", '');
        Customer.SetFilter("Bill-to Customer No.", '%1', '');
        Customer.SetFilter("Gen. Bus. Posting Group", '<>%1', '');
        Customer.SetFilter("VAT Bus. Posting Group", '<>%1', '');
        Customer.SetFilter("Customer Posting Group", '<>%1', '');
        if Customer.FindSet() then
            repeat
                Scanned += 1;
                if CustPostingGroup.Get(Customer."Customer Posting Group") then
                    if (CustPostingGroup."Receivables Account" <> '') and not HasMandatoryBlankDim(Database::Customer, Customer."No.") then
                        if FindGLAccount(GLAccount."Gen. Posting Type"::Sale, Customer."Gen. Bus. Posting Group", Customer."VAT Bus. Posting Group", GLAccNo) then begin
                            CustNo := Customer."No.";
                            exit;
                        end;
            until (Customer.Next() = 0) or (Scanned >= 50);
        Error('no customer + Sale G/L account with complete posting setup found in company %1', CompanyName());
    end;

    procedure FindPurchaseFixture(var VendNo: Code[20]; var GLAccNo: Code[20])
    var
        Vendor: Record Vendor;
        VendPostingGroup: Record "Vendor Posting Group";
        GLAccount: Record "G/L Account";
        Scanned: Integer;
    begin
        Vendor.SetRange(Blocked, Vendor.Blocked::" ");
        Vendor.SetRange("Privacy Blocked", false);
        Vendor.SetRange("Currency Code", '');
        Vendor.SetFilter("Pay-to Vendor No.", '%1', '');
        Vendor.SetFilter("Gen. Bus. Posting Group", '<>%1', '');
        Vendor.SetFilter("VAT Bus. Posting Group", '<>%1', '');
        Vendor.SetFilter("Vendor Posting Group", '<>%1', '');
        if Vendor.FindSet() then
            repeat
                Scanned += 1;
                if VendPostingGroup.Get(Vendor."Vendor Posting Group") then
                    if (VendPostingGroup."Payables Account" <> '') and not HasMandatoryBlankDim(Database::Vendor, Vendor."No.") then
                        if FindGLAccount(GLAccount."Gen. Posting Type"::Purchase, Vendor."Gen. Bus. Posting Group", Vendor."VAT Bus. Posting Group", GLAccNo) then begin
                            VendNo := Vendor."No.";
                            exit;
                        end;
            until (Vendor.Next() = 0) or (Scanned >= 50);
        Error('no vendor + Purchase G/L account with complete posting setup found in company %1', CompanyName());
    end;

    local procedure FindGLAccount(PostingType: Enum "General Posting Type"; GenBus: Code[20]; VATBus: Code[20]; var GLAccNo: Code[20]): Boolean
    var
        GLAccount: Record "G/L Account";
        GenPostingSetup: Record "General Posting Setup";
        VATPostingSetup: Record "VAT Posting Setup";
    begin
        GLAccount.SetRange("Account Type", GLAccount."Account Type"::Posting);
        GLAccount.SetRange("Direct Posting", true);
        GLAccount.SetRange(Blocked, false);
        GLAccount.SetRange("Gen. Posting Type", PostingType);
        GLAccount.SetFilter("Gen. Prod. Posting Group", '<>%1', '');
        GLAccount.SetFilter("VAT Prod. Posting Group", '<>%1', '');
        if GLAccount.FindSet() then
            repeat
                if GenPostingSetup.Get(GenBus, GLAccount."Gen. Prod. Posting Group") then
                    if not GenPostingSetup.Blocked then
                        if VATPostingSetup.Get(VATBus, GLAccount."VAT Prod. Posting Group") then
                            if (not VATPostingSetup.Blocked) and
                               (VATPostingSetup."VAT Calculation Type" = VATPostingSetup."VAT Calculation Type"::"Normal VAT") and
                               (VATPostingSetup."Sales VAT Account" <> '') and (VATPostingSetup."Purchase VAT Account" <> '') and
                               not HasMandatoryBlankDim(Database::"G/L Account", GLAccount."No.")
                            then begin
                                GLAccNo := GLAccount."No.";
                                exit(true);
                            end;
            until GLAccount.Next() = 0;
        exit(false);
    end;

    local procedure HasMandatoryBlankDim(TableId: Integer; No: Code[20]): Boolean
    var
        DefaultDim: Record "Default Dimension";
    begin
        DefaultDim.SetRange("Table ID", TableId);
        DefaultDim.SetRange("No.", No);
        DefaultDim.SetRange("Value Posting", DefaultDim."Value Posting"::"Code Mandatory");
        DefaultDim.SetRange("Dimension Value Code", '');
        exit(not DefaultDim.IsEmpty());
    end;

    procedure CreateSalesDoc(DocType: Enum "Sales Document Type"; CustNo: Code[20]; GLAccNo: Code[20]; var SalesHeader: Record "Sales Header")
    var
        SalesLine: Record "Sales Line";
    begin
        SalesHeader.Init();
        SalesHeader."Document Type" := DocType;
        SalesHeader."No." := '';
        SalesHeader.Insert(true);
        SalesHeader.Validate("Sell-to Customer No.", CustNo);
        SalesHeader.Validate("Posting Date", WorkDate());
        SalesHeader."External Document No." := CopyStr(UniqueSuffix(), 1, MaxStrLen(SalesHeader."External Document No."));
        SalesHeader.Modify(true);

        SalesLine.Init();
        SalesLine."Document Type" := SalesHeader."Document Type";
        SalesLine."Document No." := SalesHeader."No.";
        SalesLine."Line No." := 10000;
        SalesLine.Insert(true);
        SalesLine.Validate(Type, SalesLine.Type::"G/L Account");
        SalesLine.Validate("No.", GLAccNo);
        SalesLine.Validate(Quantity, 1);
        SalesLine.Validate("Unit Price", 100);
        SalesLine.Modify(true);
        SalesHeader.Get(SalesHeader."Document Type", SalesHeader."No.");
    end;

    procedure CreatePurchaseDoc(DocType: Enum "Purchase Document Type"; VendNo: Code[20]; GLAccNo: Code[20]; var PurchHeader: Record "Purchase Header")
    var
        PurchLine: Record "Purchase Line";
    begin
        PurchHeader.Init();
        PurchHeader."Document Type" := DocType;
        PurchHeader."No." := '';
        PurchHeader.Insert(true);
        PurchHeader.Validate("Buy-from Vendor No.", VendNo);
        PurchHeader.Validate("Posting Date", WorkDate());
        PurchHeader."Vendor Invoice No." := CopyStr(UniqueSuffix(), 1, MaxStrLen(PurchHeader."Vendor Invoice No."));
        PurchHeader."Vendor Cr. Memo No." := PurchHeader."Vendor Invoice No.";
        PurchHeader.Modify(true);

        PurchLine.Init();
        PurchLine."Document Type" := PurchHeader."Document Type";
        PurchLine."Document No." := PurchHeader."No.";
        PurchLine."Line No." := 10000;
        PurchLine.Insert(true);
        PurchLine.Validate(Type, PurchLine.Type::"G/L Account");
        PurchLine.Validate("No.", GLAccNo);
        PurchLine.Validate(Quantity, 1);
        PurchLine.Validate("Direct Unit Cost", 100);
        PurchLine.Modify(true);
        PurchHeader.Get(PurchHeader."Document Type", PurchHeader."No.");
    end;

    // ---- journal fixtures ----------------------------------------------------------------------------

    // Two distinct direct-posting balance-sheet accounts with no general posting type (no VAT), so a
    // +/- pair is a plain balanced transfer.
    procedure FindBalanceAccounts(var AccNo1: Code[20]; var AccNo2: Code[20])
    var
        GLAccount: Record "G/L Account";
    begin
        AccNo1 := '';
        AccNo2 := '';
        GLAccount.SetRange("Account Type", GLAccount."Account Type"::Posting);
        GLAccount.SetRange("Direct Posting", true);
        GLAccount.SetRange(Blocked, false);
        GLAccount.SetRange("Income/Balance", GLAccount."Income/Balance"::"Balance Sheet");
        GLAccount.SetRange("Gen. Posting Type", GLAccount."Gen. Posting Type"::" ");
        GLAccount.SetRange("Gen. Bus. Posting Group", '');
        GLAccount.SetRange("Gen. Prod. Posting Group", '');
        GLAccount.SetRange("VAT Prod. Posting Group", '');
        if GLAccount.FindSet() then
            repeat
                if not HasMandatoryBlankDim(Database::"G/L Account", GLAccount."No.") then
                    if AccNo1 = '' then
                        AccNo1 := GLAccount."No."
                    else begin
                        AccNo2 := GLAccount."No.";
                        exit;
                    end;
            until GLAccount.Next() = 0;
        Error('need two direct-posting balance-sheet G/L accounts without posting groups in company %1', CompanyName());
    end;

    procedure CreateGenJnlBatch(var Template: Code[10]; var Batch: Code[10])
    var
        GenJnlTemplate: Record "Gen. Journal Template";
        GenJnlBatch: Record "Gen. Journal Batch";
    begin
        Template := TemplateNameTok;
        if not GenJnlTemplate.Get(Template) then begin
            GenJnlTemplate.Init();
            GenJnlTemplate.Name := Template;
            GenJnlTemplate.Description := 'Wicket actions test';
            GenJnlTemplate.Validate(Type, GenJnlTemplate.Type::General);
            GenJnlTemplate.Recurring := false;
            GenJnlTemplate.Insert(true);
        end;
        GenJnlTemplate."Force Posting Report" := false;
        GenJnlTemplate."No. Series" := '';
        GenJnlTemplate.Modify();

        Batch := NewBatchName();
        GenJnlBatch.Init();
        GenJnlBatch."Journal Template Name" := Template;
        GenJnlBatch.Name := Batch;
        GenJnlBatch.Description := 'Wicket actions test';
        GenJnlBatch.Insert(true);
        GenJnlBatch."No. Series" := '';
        GenJnlBatch."Posting No. Series" := '';
        GenJnlBatch."Bal. Account No." := '';
        GenJnlBatch.Modify();
    end;

    procedure AddGenJnlLine(Template: Code[10]; Batch: Code[10]; LineNo: Integer; DocNo: Code[20]; AccNo: Code[20]; Amount: Decimal)
    var
        GenJnlLine: Record "Gen. Journal Line";
    begin
        GenJnlLine.Init();
        GenJnlLine."Journal Template Name" := Template;
        GenJnlLine."Journal Batch Name" := Batch;
        GenJnlLine."Line No." := LineNo;
        GenJnlLine.Insert(true);
        GenJnlLine.Validate("Posting Date", WorkDate());
        GenJnlLine."Document No." := DocNo;
        GenJnlLine.Validate("Account Type", GenJnlLine."Account Type"::"G/L Account");
        GenJnlLine.Validate("Account No.", AccNo);
        GenJnlLine.Validate(Amount, Amount);
        GenJnlLine.Description := 'Wicket actions test';
        GenJnlLine.Modify(true);
    end;

    // An inventory item (no tracking, no variants) plus a location it can be adjusted into, with the
    // inventory and adjustment accounts in place.
    procedure FindItemFixture(var ItemNo: Code[20]; var LocationCode: Code[10])
    var
        Item: Record Item;
        ItemVariant: Record "Item Variant";
        GenPostingSetup: Record "General Posting Setup";
        Scanned: Integer;
    begin
        Item.SetRange(Type, Item.Type::Inventory);
        Item.SetRange(Blocked, false);
        Item.SetRange("Item Tracking Code", '');
        Item.SetFilter("Inventory Posting Group", '<>%1', '');
        Item.SetFilter("Gen. Prod. Posting Group", '<>%1', '');
        Item.SetFilter("Base Unit of Measure", '<>%1', '');
        Item.SetFilter("Costing Method", '<>%1', Item."Costing Method"::Specific);
        if Item.FindSet() then
            repeat
                Scanned += 1;
                ItemVariant.SetRange("Item No.", Item."No.");
                if ItemVariant.IsEmpty() and not HasMandatoryBlankDim(Database::Item, Item."No.") then
                    if GenPostingSetup.Get('', Item."Gen. Prod. Posting Group") then
                        if (GenPostingSetup."Inventory Adjmt. Account" <> '') and not GenPostingSetup.Blocked then
                            if FindAdjustmentLocation(Item."Inventory Posting Group", LocationCode) then begin
                                ItemNo := Item."No.";
                                exit;
                            end;
            until (Item.Next() = 0) or (Scanned >= 100);
        Error('no inventory item with complete adjustment posting setup found in company %1', CompanyName());
    end;

    local procedure FindAdjustmentLocation(InvPostingGroup: Code[20]; var LocationCode: Code[10]): Boolean
    var
        InventorySetup: Record "Inventory Setup";
        Location: Record Location;
        InvPostingSetup: Record "Inventory Posting Setup";
    begin
        InventorySetup.Get();
        if not InventorySetup."Location Mandatory" then
            if InvPostingSetup.Get('', InvPostingGroup) then
                if InvPostingSetup."Inventory Account" <> '' then begin
                    LocationCode := '';
                    exit(true);
                end;
        Location.SetRange("Use As In-Transit", false);
        Location.SetRange("Bin Mandatory", false);
        Location.SetRange("Directed Put-away and Pick", false);
        if Location.FindSet() then
            repeat
                if InvPostingSetup.Get(Location.Code, InvPostingGroup) then
                    if InvPostingSetup."Inventory Account" <> '' then begin
                        LocationCode := Location.Code;
                        exit(true);
                    end;
            until Location.Next() = 0;
        exit(false);
    end;

    procedure CreateItemJnlBatch(var Template: Code[10]; var Batch: Code[10])
    var
        ItemJnlTemplate: Record "Item Journal Template";
        ItemJnlBatch: Record "Item Journal Batch";
    begin
        Template := TemplateNameTok;
        if not ItemJnlTemplate.Get(Template) then begin
            ItemJnlTemplate.Init();
            ItemJnlTemplate.Name := Template;
            ItemJnlTemplate.Description := 'Wicket actions test';
            ItemJnlTemplate.Validate(Type, ItemJnlTemplate.Type::Item);
            ItemJnlTemplate.Recurring := false;
            ItemJnlTemplate.Insert(true);
        end;
        ItemJnlTemplate."Force Posting Report" := false;
        ItemJnlTemplate."No. Series" := '';
        ItemJnlTemplate.Modify();

        Batch := NewBatchName();
        ItemJnlBatch.Init();
        ItemJnlBatch."Journal Template Name" := Template;
        ItemJnlBatch.Name := Batch;
        ItemJnlBatch.Description := 'Wicket actions test';
        ItemJnlBatch.Insert(true);
        ItemJnlBatch."No. Series" := '';
        ItemJnlBatch."Posting No. Series" := '';
        ItemJnlBatch.Modify();
    end;

    procedure AddItemJnlLine(Template: Code[10]; Batch: Code[10]; DocNo: Code[20]; ItemNo: Code[20]; LocationCode: Code[10]; Qty: Decimal)
    var
        ItemJnlLine: Record "Item Journal Line";
    begin
        ItemJnlLine.Init();
        ItemJnlLine."Journal Template Name" := Template;
        ItemJnlLine."Journal Batch Name" := Batch;
        ItemJnlLine."Line No." := 10000;
        ItemJnlLine.Insert(true);
        ItemJnlLine.Validate("Posting Date", WorkDate());
        ItemJnlLine.Validate("Entry Type", ItemJnlLine."Entry Type"::"Positive Adjmt.");
        ItemJnlLine."Document No." := DocNo;
        ItemJnlLine.Validate("Item No.", ItemNo);
        if LocationCode <> '' then
            ItemJnlLine.Validate("Location Code", LocationCode);
        ItemJnlLine.Validate(Quantity, Qty);
        ItemJnlLine.Validate("Unit Amount", 10);
        ItemJnlLine.Modify(true);
    end;

    // ---- names ---------------------------------------------------------------------------------------

    procedure UniqueSuffix(): Text
    begin
        exit(UpperCase(CopyStr(DelChr(Format(CreateGuid()), '=', '{}-'), 1, 12)));
    end;

    procedure NewBatchName(): Code[10]
    begin
        exit(CopyStr('T' + UniqueSuffix(), 1, 10));
    end;

    procedure NewDocNo(): Code[20]
    begin
        exit(CopyStr('BCMAG' + UniqueSuffix(), 1, 20));
    end;
}
