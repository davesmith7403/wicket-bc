codeunit 94204 "Bcmag Act Post Item Journal"
{
    // Action wrapper: post an item journal batch via the non-interactive Item Jnl.-Post Batch (23).
    // invoke { codeunitId: 94204, procedure: "PostItemJournal", args: {...} }
    // args:  { template, batch, preview? }
    // preview: args.preview = true posts nothing: Bcmag Act Preview runs BC's posting preview through
    //        Item Jnl.-Post (241) in preview mode (dialogs hidden) after the same guards, and the result is
    //        { preview: true, wouldPost, errors, entries, glAccounts, template, batch }.
    // result:{ posted:true, template, batch, itemRegisterNo, firstEntryNo, lastEntryNo }
    //        (posts to item ledger entries, not a single document — the Item Register is the evidence)
    //        If posting created no new item register (all lines were empty), the register fields are
    //        replaced by noEntriesPosted:true so the caller can tell nothing actually happened.
    // Posting COMMITs — the entries are durable, outside any Wicket rollback.
    //
    // Item Jnl.-Post (241), the interactive front end, refuses a template with Force Posting Report
    // (and a recurring template posted with a Posting Date filter — never the case here: the line set is
    // exactly template + batch) before calling the batch post; the first is a business rule and is
    // replicated here (verified against the 28.x source of 241.Code).
    //
    // Post-commit failures: Item Jnl.-Post Batch commits the entries, then refreshes analysis views,
    // moves the batch and runs subscribers. An error there makes Codeunit.Run return false after the
    // journal WAS posted; an item register for this batch above the pre-post watermark proves it, and the
    // wrapper then answers posted:true with postCommitWarning instead of a failure.

    trigger OnRun()
    var
        Ctx: Codeunit "Bcmag Invoke Context";
        Helper: Codeunit "Bcmag Act Helper";
        Preview: Codeunit "Bcmag Act Preview";
        ItemJnlBatch: Record "Item Journal Batch";
        ItemJnlLine: Record "Item Journal Line";
        ItemRegister: Record "Item Register";
        Args, Result: JsonObject;
        Template, Batch, PostingError: Text;
        LastRegisterNo: Integer;
        TemplateTooLongErr: Label 'template must be at most %1 characters', Comment = '%1 = maximum length of Journal Template Name';
        BatchTooLongErr: Label 'batch must be at most %1 characters', Comment = '%1 = maximum length of Journal Batch Name';
        BatchMissingErr: Label 'journal batch %1/%2 does not exist', Comment = '%1 = journal template name, %2 = journal batch name';
        PostingFailedErr: Label 'posting item journal %1 / %2 failed: %3', Comment = '%1 = journal template name, %2 = journal batch name, %3 = posting error text';
    begin
        Args := Ctx.GetArgs();
        Template := Helper.RequireText(Args, 'template');
        Batch := Helper.RequireText(Args, 'batch');

        // Validate lengths up front — an oversized Text thrown into a Code[10] filter/Get raises a
        // raw overflow error instead of a usable message.
        if StrLen(Template) > MaxStrLen(ItemJnlLine."Journal Template Name") then
            Error(TemplateTooLongErr, MaxStrLen(ItemJnlLine."Journal Template Name"));
        if StrLen(Batch) > MaxStrLen(ItemJnlLine."Journal Batch Name") then
            Error(BatchTooLongErr, MaxStrLen(ItemJnlLine."Journal Batch Name"));

        // A typo'd template/batch must be distinguishable from an existing-but-empty batch.
        if not ItemJnlBatch.Get(Template, Batch) then
            Error(BatchMissingErr, Template, Batch);

        CheckTemplateGuards(Template);

        ItemJnlLine.SetRange("Journal Template Name", Template);
        ItemJnlLine.SetRange("Journal Batch Name", Batch);
        if not ItemJnlLine.FindFirst() then
            Error('item journal %1 / %2 has no lines to post', Template, Batch);

        if Helper.GetBool(Args, 'preview', false) then begin
            Result := Preview.PreviewItemJournal(ItemJnlLine);
            Result.Add('template', Template);
            Result.Add('batch', Batch);
            Ctx.SetResult(Result);
            exit;
        end;

        // Capture the last item register no. pre-post so the evidence below is provably NEW.
        if ItemRegister.FindLast() then
            LastRegisterNo := ItemRegister."No.";

        // ClearLastError first, and compose the message so it still identifies the batch when a
        // posting abort path leaves GetLastErrorText empty.
        ClearLastError();
        if not Codeunit.Run(Codeunit::"Item Jnl.-Post Batch", ItemJnlLine) then begin
            PostingError := GetLastErrorText();
            if not FindNewRegister(Template, Batch, LastRegisterNo, true, ItemRegister) then
                Error(PostingFailedErr, Template, Batch, PostingError);
            Result.Add('posted', true);
            Result.Add('template', Template);
            Result.Add('batch', Batch);
            AddRegister(ItemRegister, Result);
            Result.Add('postCommitWarning', PostingError);
            Result.Add('postCommitEvidence', 'an item register for this journal batch was created during this call');
            Ctx.SetResult(Result);
            exit;
        end;

        Result.Add('posted', true);
        Result.Add('template', Template);
        Result.Add('batch', Batch);
        // Posting evidence: the item register this run created — otherwise the run posted no entries
        // (e.g. the batch held only empty lines) and we say so explicitly.
        if FindNewRegister(Template, Batch, LastRegisterNo, false, ItemRegister) then
            AddRegister(ItemRegister, Result)
        else
            Result.Add('noEntriesPosted', true);
        Ctx.SetResult(Result);
    end;

    // The register this run created: above the pre-post watermark, this batch name and this session's
    // user. Item Register has no template field in 28.x, and "DEFAULT" is the batch name of nearly every
    // item-journal template, so the batch alone would credit another session's posting to us — on the
    // failure path that turns an unposted journal into "posted:true". (Source Code is no key: it comes
    // from each line, and lines created through an API often leave it blank.) On that path (Unique) two
    // matching registers are ambiguous and the original failure stands.
    local procedure FindNewRegister(Template: Text; Batch: Text; LastRegisterNo: Integer; Unique: Boolean; var ItemRegister: Record "Item Register"): Boolean
    begin
        ItemRegister.Reset();
        ItemRegister.SetRange("Journal Batch Name", Batch);
        ItemRegister.SetRange("User ID", CopyStr(UserId(), 1, MaxStrLen(ItemRegister."User ID")));
        ItemRegister.SetFilter("No.", '>%1', LastRegisterNo);
        if Unique and (ItemRegister.Count() <> 1) then
            exit(false);
        exit(ItemRegister.FindLast());
    end;

    local procedure AddRegister(ItemRegister: Record "Item Register"; var Result: JsonObject)
    begin
        Result.Add('itemRegisterNo', ItemRegister."No.");
        Result.Add('firstEntryNo', ItemRegister."From Entry No.");
        Result.Add('lastEntryNo', ItemRegister."To Entry No.");
    end;

    local procedure CheckTemplateGuards(Template: Text)
    var
        ItemJnlTemplate: Record "Item Journal Template";
        ForcePostingReportErr: Label 'journal template %1 has Force Posting Report set, so it must be posted through its posting report, not directly', Comment = '%1 = journal template name';
    begin
        ItemJnlTemplate.Get(Template);
        if ItemJnlTemplate."Force Posting Report" then
            Error(ForcePostingReportErr, Template);
    end;
}
