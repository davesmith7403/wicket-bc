codeunit 94353 "Bcmag Act Journal Test"
{
    // post-gen-journal and post-item-journal end to end through the dispatcher's `action` operation,
    // on a template + batch created per test.
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibraryAssert: Codeunit "Library Assert";
        Helper: Codeunit "Bcmag Act Test Helper";
        PostGenJournalTok: Label 'post-gen-journal', Locked = true;
        PostItemJournalTok: Label 'post-item-journal', Locked = true;

    [Test]
    procedure BalancedGeneralJournalPostsAndReturnsRegisterEvidence()
    var
        GenJnlLine: Record "Gen. Journal Line";
        GLRegister: Record "G/L Register";
        GLEntry: Record "G/L Entry";
        Args, Response, Value: JsonObject;
        Template, Batch: Code[10];
        AccNo1, AccNo2, DocNo: Code[20];
        Status, LastRegisterNo: Integer;
    begin
        Helper.Initialize();
        Helper.FindBalanceAccounts(AccNo1, AccNo2);
        Helper.CreateGenJnlBatch(Template, Batch);
        DocNo := Helper.NewDocNo();
        Helper.AddGenJnlLine(Template, Batch, 10000, DocNo, AccNo1, 100);
        Helper.AddGenJnlLine(Template, Batch, 20000, DocNo, AccNo2, -100);
        if GLRegister.FindLast() then
            LastRegisterNo := GLRegister."No.";

        Args.Add('template', Template);
        Args.Add('batch', Batch);
        Response := Helper.RunAction(Helper.ActionData(PostGenJournalTok, CreateGuidNull(), Args), '', Status);

        Helper.AssertOk(Status, Response, 'balanced gen journal');
        Value := Helper.ValueOf(Response);
        LibraryAssert.AreEqual(Template, Helper.Txt(Value, 'template'), 'template echoed');
        LibraryAssert.AreEqual(Batch, Helper.Txt(Value, 'batch'), 'batch echoed');
        LibraryAssert.IsFalse(Value.Contains('noEntriesPosted'), 'entries were posted: ' + Helper.Describe(Response));
        LibraryAssert.IsTrue(Helper.Int(Value, 'glRegisterNo') > LastRegisterNo, 'the register is new: ' + Helper.Describe(Response));
        LibraryAssert.IsTrue(GLRegister.Get(Helper.Int(Value, 'glRegisterNo')), 'glRegisterNo names a G/L register');
        LibraryAssert.AreEqual(Batch, GLRegister."Journal Batch Name", 'register belongs to the batch');
        LibraryAssert.AreEqual(GLRegister."From Entry No.", Helper.Int(Value, 'firstEntryNo'), 'firstEntryNo');
        LibraryAssert.AreEqual(GLRegister."To Entry No.", Helper.Int(Value, 'lastEntryNo'), 'lastEntryNo');

        GLEntry.SetRange("Entry No.", Helper.Int(Value, 'firstEntryNo'), Helper.Int(Value, 'lastEntryNo'));
        GLEntry.SetRange("Document No.", DocNo);
        LibraryAssert.AreEqual(2, GLEntry.Count(), 'both lines became G/L entries inside the reported range');

        GenJnlLine.SetRange("Journal Template Name", Template);
        GenJnlLine.SetRange("Journal Batch Name", Batch);
        // Gen. Jnl.-Post Batch leaves one blank line carrying the next Document No. (standard); every
        // line that held an account is gone.
        GenJnlLine.SetFilter("Account No.", '<>%1', '');
        LibraryAssert.IsTrue(GenJnlLine.IsEmpty(), 'posted lines are removed from the batch: ' + DumpGen(GenJnlLine));
    end;

    [Test]
    procedure UnbalancedGeneralJournalFailsAndPostsNothing()
    var
        GenJnlLine: Record "Gen. Journal Line";
        GLRegister: Record "G/L Register";
        GLEntry: Record "G/L Entry";
        Args, Response: JsonObject;
        Template, Batch: Code[10];
        AccNo1, AccNo2, DocNo: Code[20];
        Status, LastRegisterNo: Integer;
    begin
        Helper.Initialize();
        Helper.FindBalanceAccounts(AccNo1, AccNo2);
        Helper.CreateGenJnlBatch(Template, Batch);
        DocNo := Helper.NewDocNo();
        Helper.AddGenJnlLine(Template, Batch, 10000, DocNo, AccNo1, 100);
        if GLRegister.FindLast() then
            LastRegisterNo := GLRegister."No.";

        Args.Add('template', Template);
        Args.Add('batch', Batch);
        Response := Helper.RunAction(Helper.ActionData(PostGenJournalTok, CreateGuidNull(), Args), '', Status);

        Helper.AssertProblem(Status, Response, 422, 'action-failed', 'unbalanced gen journal');
        LibraryAssert.IsTrue(StrPos(Helper.Txt(Response, 'detail'), 'posting general journal') > 0, 'detail identifies the batch post: ' + Helper.Describe(Response));
        LibraryAssert.IsTrue(StrPos(Helper.Txt(Response, 'detail'), Batch) > 0, 'detail names the batch: ' + Helper.Describe(Response));

        GLRegister.Reset();
        if GLRegister.FindLast() then;
        LibraryAssert.AreEqual(LastRegisterNo, GLRegister."No.", 'no G/L register was created');
        GLEntry.SetRange("Document No.", DocNo);
        LibraryAssert.IsTrue(GLEntry.IsEmpty(), 'no G/L entries were posted');
        GenJnlLine.SetRange("Journal Template Name", Template);
        GenJnlLine.SetRange("Journal Batch Name", Batch);
        LibraryAssert.AreEqual(1, GenJnlLine.Count(), 'the unposted line stays in the batch');
    end;

    [Test]
    procedure ItemJournalPositiveAdjustmentPostsAnItemLedgerEntry()
    var
        ItemJnlLine: Record "Item Journal Line";
        ItemRegister: Record "Item Register";
        ItemLedgerEntry: Record "Item Ledger Entry";
        Args, Response, Value: JsonObject;
        Template, Batch, LocationCode: Code[10];
        ItemNo, DocNo: Code[20];
        Status, LastRegisterNo: Integer;
    begin
        Helper.Initialize();
        Helper.FindItemFixture(ItemNo, LocationCode);
        Helper.CreateItemJnlBatch(Template, Batch);
        DocNo := Helper.NewDocNo();
        Helper.AddItemJnlLine(Template, Batch, DocNo, ItemNo, LocationCode, 3);
        if ItemRegister.FindLast() then
            LastRegisterNo := ItemRegister."No.";

        Args.Add('template', Template);
        Args.Add('batch', Batch);
        Response := Helper.RunAction(Helper.ActionData(PostItemJournalTok, CreateGuidNull(), Args), '', Status);

        Helper.AssertOk(Status, Response, 'item journal');
        Value := Helper.ValueOf(Response);
        LibraryAssert.IsFalse(Value.Contains('noEntriesPosted'), 'entries were posted: ' + Helper.Describe(Response));
        LibraryAssert.IsTrue(Helper.Int(Value, 'itemRegisterNo') > LastRegisterNo, 'the item register is new: ' + Helper.Describe(Response));
        LibraryAssert.IsTrue(ItemRegister.Get(Helper.Int(Value, 'itemRegisterNo')), 'itemRegisterNo names an item register');
        LibraryAssert.AreEqual(Batch, ItemRegister."Journal Batch Name", 'register belongs to the batch');

        ItemLedgerEntry.SetRange("Item No.", ItemNo);
        ItemLedgerEntry.SetRange("Document No.", DocNo);
        LibraryAssert.AreEqual(1, ItemLedgerEntry.Count(), 'one item ledger entry');
        ItemLedgerEntry.FindFirst();
        LibraryAssert.IsTrue(ItemLedgerEntry."Entry Type" = ItemLedgerEntry."Entry Type"::"Positive Adjmt.", 'entry type is positive adjustment');
        LibraryAssert.AreEqual(3, ItemLedgerEntry.Quantity, 'quantity');
        LibraryAssert.IsTrue((ItemLedgerEntry."Entry No." >= Helper.Int(Value, 'firstEntryNo')) and (ItemLedgerEntry."Entry No." <= Helper.Int(Value, 'lastEntryNo')), 'the entry lies inside the reported register range: ' + Helper.Describe(Response));

        ItemJnlLine.SetRange("Journal Template Name", Template);
        ItemJnlLine.SetRange("Journal Batch Name", Batch);
        // Item Jnl.-Post Batch leaves one blank line carrying the next Document No. (standard).
        ItemJnlLine.SetFilter("Item No.", '<>%1', '');
        LibraryAssert.IsTrue(ItemJnlLine.IsEmpty(), 'posted lines are removed from the batch: ' + DumpItem(ItemJnlLine));
    end;

    local procedure DumpGen(var L: Record "Gen. Journal Line") T: Text
    begin
        if L.FindSet() then
            repeat
                T += StrSubstNo('[line %1 acc %2 amt %3 doc %4 date %5] ', L."Line No.", L."Account No.", L.Amount, L."Document No.", L."Posting Date");
            until L.Next() = 0;
    end;

    local procedure DumpItem(var L: Record "Item Journal Line") T: Text
    begin
        if L.FindSet() then
            repeat
                T += StrSubstNo('[line %1 item %2 qty %3 doc %4 date %5] ', L."Line No.", L."Item No.", L.Quantity, L."Document No.", L."Posting Date");
            until L.Next() = 0;
    end;

    local procedure CreateGuidNull(): Guid
    var
        Empty: Guid;
    begin
        exit(Empty);
    end;
}
