codeunit 94203 "Bcmag Act Post Gen Journal"
{
    // Action wrapper: post a general journal batch via the non-interactive Gen. Jnl.-Post Batch (13).
    // Also covers payment / cash-receipt journals — they are just other templates over table 81.
    // invoke { codeunitId: 94203, procedure: "PostGeneralJournal", args: {...} }
    // args:  { template, batch, preview? }
    // preview: args.preview = true posts nothing: Bcmag Act Preview runs BC's posting preview through
    //        Gen. Jnl.-Post (231) in preview mode (dialogs hidden) after the same guards, and the result is
    //        { preview: true, wouldPost, errors, entries, glAccounts, template, batch }.
    // result:{ posted:true, template, batch, glRegisterNo, firstEntryNo, lastEntryNo }
    //        (a journal posts to entries, not a single document — the G/L Register is the evidence)
    //        If posting created no new G/L register (all lines were empty), the register fields are
    //        replaced by noEntriesPosted:true so the caller can tell nothing actually happened.
    // Posting COMMITs — the entries are durable, outside any Wicket rollback.
    //
    // Why codeunit 13 and not Gen. Jnl.-Post (231): 231 is the interactive front end — confirm dialogs,
    // result messages, and with "Post with Job Queue" it only SCHEDULES the post, which would make the
    // result a lie. But 231 also refuses three things before calling 13, and those refusals are business
    // rules, not UI, so they are replicated here (verified against the 28.x source of 231.Code):
    //   - a template with Force Posting Report must be posted through its report, never directly;
    //   - a Jobs template whose Source Code equals Source Code Setup "Job G/L WIP" must not be posted
    //     (those lines belong to the WIP posting process);
    //   - a recurring template must not be posted with a Posting Date filter — never applies here: the
    //     line set is exactly template + batch, no date filter is ever set.
    //
    // Post-commit failures: 13 commits the entries, then refreshes analysis views and runs subscribers.
    // An error there makes Codeunit.Run return false after the journal WAS posted. On false the wrapper
    // looks for a G/L register of this template/batch above the pre-post watermark: found → posted:true
    // with postCommitWarning (the error) and the register as evidence; not found → the failure it was.

    trigger OnRun()
    var
        Ctx: Codeunit "Bcmag Invoke Context";
        Helper: Codeunit "Bcmag Act Helper";
        Preview: Codeunit "Bcmag Act Preview";
        GenJnlBatch: Record "Gen. Journal Batch";
        GenJnlLine: Record "Gen. Journal Line";
        GLRegister: Record "G/L Register";
        Args, Result: JsonObject;
        Template, Batch, PostingError: Text;
        LastRegisterNo: Integer;
        TemplateTooLongErr: Label 'template must be at most %1 characters', Comment = '%1 = maximum length of Journal Template Name';
        BatchTooLongErr: Label 'batch must be at most %1 characters', Comment = '%1 = maximum length of Journal Batch Name';
        BatchMissingErr: Label 'journal batch %1/%2 does not exist', Comment = '%1 = journal template name, %2 = journal batch name';
        PostingFailedErr: Label 'posting general journal %1 / %2 failed: %3', Comment = '%1 = journal template name, %2 = journal batch name, %3 = posting error text';
    begin
        Args := Ctx.GetArgs();
        Template := Helper.RequireText(Args, 'template');
        Batch := Helper.RequireText(Args, 'batch');

        // Validate lengths up front — an oversized Text thrown into a Code[10] filter/Get raises a
        // raw overflow error instead of a usable message.
        if StrLen(Template) > MaxStrLen(GenJnlLine."Journal Template Name") then
            Error(TemplateTooLongErr, MaxStrLen(GenJnlLine."Journal Template Name"));
        if StrLen(Batch) > MaxStrLen(GenJnlLine."Journal Batch Name") then
            Error(BatchTooLongErr, MaxStrLen(GenJnlLine."Journal Batch Name"));

        // A typo'd template/batch must be distinguishable from an existing-but-empty batch.
        if not GenJnlBatch.Get(Template, Batch) then
            Error(BatchMissingErr, Template, Batch);

        CheckTemplateGuards(Template);

        // The batch-post codeunit reads the batch identity from the passed line's Template/Batch.
        GenJnlLine.SetRange("Journal Template Name", Template);
        GenJnlLine.SetRange("Journal Batch Name", Batch);
        if not GenJnlLine.FindFirst() then
            Error('general journal %1 / %2 has no lines to post', Template, Batch);

        if Helper.GetBool(Args, 'preview', false) then begin
            Result := Preview.PreviewGenJournal(GenJnlLine);
            Result.Add('template', Template);
            Result.Add('batch', Batch);
            Ctx.SetResult(Result);
            exit;
        end;

        // Capture the last G/L register no. pre-post so the evidence below is provably NEW.
        if GLRegister.FindLast() then
            LastRegisterNo := GLRegister."No.";

        // ClearLastError first, and compose the message so it still identifies the batch when a
        // posting abort path leaves GetLastErrorText empty.
        ClearLastError();
        if not Codeunit.Run(Codeunit::"Gen. Jnl.-Post Batch", GenJnlLine) then begin
            PostingError := GetLastErrorText();
            if not FindNewRegister(Template, Batch, LastRegisterNo, true, GLRegister) then
                Error(PostingFailedErr, Template, Batch, PostingError);
            Result.Add('posted', true);
            Result.Add('template', Template);
            Result.Add('batch', Batch);
            AddRegister(GLRegister, Result);
            Result.Add('postCommitWarning', PostingError);
            Result.Add('postCommitEvidence', 'a G/L register for this journal batch was created during this call');
            Ctx.SetResult(Result);
            exit;
        end;

        Result.Add('posted', true);
        Result.Add('template', Template);
        Result.Add('batch', Batch);
        // Posting evidence: the G/L register this run created — otherwise the run posted no entries
        // (e.g. the batch held only empty lines) and we say so explicitly.
        if FindNewRegister(Template, Batch, LastRegisterNo, false, GLRegister) then
            AddRegister(GLRegister, Result)
        else
            Result.Add('noEntriesPosted', true);
        Ctx.SetResult(Result);
    end;

    // The register this run created: this template AND batch (batch names repeat across templates),
    // above the pre-post watermark, so a concurrent posting from another session can neither hide our
    // register nor be mis-attributed as ours. "Journal Templ. Name" is stamped by Gen. Jnl.-Post Line
    // when it starts the register (28.x: GLReg."Journal Templ. Name" := GenJnlTemplate.Name). Also this
    // session's user: another user posting the same template/batch concurrently is not our evidence.
    // On the failure path (Unique) the claim "our posting committed" must be unambiguous — two matching
    // registers mean we cannot tell which is ours, so the original failure stands.
    local procedure FindNewRegister(Template: Text; Batch: Text; LastRegisterNo: Integer; Unique: Boolean; var GLRegister: Record "G/L Register"): Boolean
    begin
        GLRegister.Reset();
        GLRegister.SetRange("Journal Templ. Name", Template);
        GLRegister.SetRange("Journal Batch Name", Batch);
        GLRegister.SetRange("User ID", CopyStr(UserId(), 1, MaxStrLen(GLRegister."User ID")));
        GLRegister.SetFilter("No.", '>%1', LastRegisterNo);
        if Unique and (GLRegister.Count() <> 1) then
            exit(false);
        exit(GLRegister.FindLast());
    end;

    local procedure AddRegister(GLRegister: Record "G/L Register"; var Result: JsonObject)
    begin
        Result.Add('glRegisterNo', GLRegister."No.");
        Result.Add('firstEntryNo', GLRegister."From Entry No.");
        Result.Add('lastEntryNo', GLRegister."To Entry No.");
    end;

    // The refusals Gen. Jnl.-Post (231) applies before it runs the batch post — see the header comment.
    local procedure CheckTemplateGuards(Template: Text)
    var
        GenJnlTemplate: Record "Gen. Journal Template";
        SourceCodeSetup: Record "Source Code Setup";
        ForcePostingReportErr: Label 'journal template %1 has Force Posting Report set, so it must be posted through its posting report, not directly', Comment = '%1 = journal template name';
        JobWipErr: Label 'journal template %1 is a Jobs template whose Source Code is the Job G/L WIP source code; those lines are posted by the WIP process, not directly', Comment = '%1 = journal template name';
    begin
        GenJnlTemplate.Get(Template);
        if GenJnlTemplate."Force Posting Report" then
            Error(ForcePostingReportErr, Template);
        if GenJnlTemplate.Type = GenJnlTemplate.Type::Jobs then
            if SourceCodeSetup.Get() then
                if (SourceCodeSetup."Job G/L WIP" <> '') and (GenJnlTemplate."Source Code" = SourceCodeSetup."Job G/L WIP") then
                    Error(JobWipErr, Template);
    end;
}
