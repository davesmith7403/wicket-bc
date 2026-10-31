codeunit 94118 "Bcmag Op Invoke"
{
    var
        RunnerCtx: Codeunit "Bcmag Op Runner Context";
        Recorder: Codeunit "Bcmag Change Recorder";
        JsonRead: Codeunit "Bcmag Json Read";
        Exposure: Record "Bcmag Exposure";
        Problem: Codeunit "Bcmag Problem";
        InvokeContext: Codeunit "Bcmag Invoke Context";

    procedure Run(Data: JsonObject; var Response: JsonObject; var Fail: JsonObject; var Cost: Integer): Boolean
    var
        Catalog: Record "Bcmag Procedure Catalog";
        Tok: JsonToken;
        CodeunitId: Integer;
        ProcedureName: Text;
        FailDetail: Text;
        Args, Result: JsonObject;
        NoErrorTextLbl: Label 'the wrapper failed without an error message', Locked = true;
    begin
        Cost := 1;
        if (not Data.Get('codeunitId', Tok)) or JsonRead.IsNull(Tok) then begin
            Fail := Problem.NewFailure(400, 'missing-field', 'Missing codeunitId', 'data.codeunitId is required');
            exit(false);
        end;
        // Guard the JSON type before coercing so a wrong-typed member answers a typed 400 instead of
        // the coercion error escaping the op boundary as a generic 500.
        if not Tok.IsValue() then begin
            Fail := Problem.NewFailure(400, 'invalid-field', 'Invalid codeunitId', 'data.codeunitId must be an integer');
            exit(false);
        end;
        if not TryCoerceInt(Tok.AsValue(), CodeunitId) then begin
            Fail := Problem.NewFailure(400, 'invalid-field', 'Invalid codeunitId', 'data.codeunitId must be an integer');
            exit(false);
        end;
        if (not Data.Get('procedure', Tok)) or JsonRead.IsNull(Tok) then begin
            Fail := Problem.NewFailure(400, 'missing-field', 'Missing procedure', 'data.procedure is required');
            exit(false);
        end;
        if not Tok.IsValue() then begin
            Fail := Problem.NewFailure(400, 'invalid-field', 'Invalid procedure', 'data.procedure must be a string');
            exit(false);
        end;
        if not TryCoerceText(Tok.AsValue(), ProcedureName) then begin
            Fail := Problem.NewFailure(400, 'invalid-field', 'Invalid procedure', 'data.procedure must be a string');
            exit(false);
        end;
        if Data.Get('args', Tok) then
            if not Tok.IsObject() and not JsonRead.IsNull(Tok) then begin
                // Dropping a non-object silently would run the wrapper with defaults nobody asked for.
                Fail := Problem.NewFailure(400, 'invalid-field', 'Invalid args', 'data.args must be a JSON object');
                exit(false);
            end;

        // invoke is ALWAYS deny-by-default — Open mode only bypasses if explicitly enabled.
        if not Exposure.IsAllowed(Exposure."Object Type"::Codeunit, CodeunitId, 'invoke') then begin
            Fail := Problem.NewFailure(403, 'not-exposed', 'Invoke not exposed',
                StrSubstNo('codeunit %1 is not exposed for invoke', CodeunitId));
            exit(false);
        end;
        // Catalog.Get on a Text[120] key raises an overflow error for longer input (a 500); no such
        // procedure can be enrolled, so it is simply unknown.
        if StrLen(ProcedureName) > MaxStrLen(Catalog."Procedure Name") then begin
            Fail := Problem.NewFailureSuggest(404, 'unknown-procedure', 'Unknown procedure',
                StrSubstNo('procedure name exceeds %1 characters, so it cannot be enrolled for codeunit %2', MaxStrLen(Catalog."Procedure Name"), CodeunitId),
                EnrolledProcedures(CodeunitId));
            exit(false);
        end;
        if not Catalog.Get(CodeunitId, ProcedureName) then begin
            Fail := Problem.NewFailureSuggest(404, 'unknown-procedure', 'Unknown procedure',
                StrSubstNo('procedure "%1" is not enrolled for codeunit %2', ProcedureName, CodeunitId),
                EnrolledProcedures(CodeunitId));
            exit(false);
        end;
        if not Catalog."Allow Run" then begin
            Fail := Problem.NewFailure(403, 'invoke-disabled', 'Procedure disabled',
                StrSubstNo('procedure "%1" is enrolled but Allow Run is off', ProcedureName));
            exit(false);
        end;

        if Data.Get('args', Tok) and Tok.IsObject() then
            Args := Tok.AsObject();
        InvokeContext.SetArgs(Args);

        // Codeunit.Run isolates any AL Error in the wrapper as a recoverable failure. ClearLastError
        // first so a stale message from an earlier caught error is never reported as the cause, and
        // fall back to a fixed detail when the wrapper aborted without an error text.
        ClearLastError();
        if not Codeunit.Run(Catalog."Wrapper Codeunit Id") then begin
            FailDetail := GetLastErrorText();
            if FailDetail = '' then
                FailDetail := NoErrorTextLbl;
            Fail := Problem.NewFailure(422, 'invoke-failed', 'Invoke failed', FailDetail);
            // A procedure may have committed before it failed: the dispatcher records it after rollback.
            RunnerCtx.NoteFailedRun("Bcmag Change Kind"::ProcedureRun, RunName(CodeunitId, ProcedureName), TargetOf(Args), FailDetail);
            exit(false);
        end;

        Clear(Response);
        if Catalog."Return Shape" = Catalog."Return Shape"::void then begin
            Result.Add('ok', true);
            Response.Add('value', Result);
        end else
            if InvokeContext.HasResultValue() then
                Response.Add('value', InvokeContext.GetResult())
            else begin
                Result.Add('ok', true);
                Response.Add('value', Result);
            end;
        // An enrolled procedure can change data as freely as an action: every run is in the history.
        Recorder.RecordRun("Bcmag Change Kind"::ProcedureRun, RunName(CodeunitId, ProcedureName), 0, TargetOf(Args), Recorder.SucceededOutcome(), ResultText(Response));
        exit(true);
    end;

    local procedure RunName(CodeunitId: Integer; ProcedureName: Text): Text
    begin
        exit(StrSubstNo('%1.%2', CodeunitId, ProcedureName));
    end;

    local procedure TargetOf(Args: JsonObject) SystemId: Guid
    var
        Tok: JsonToken;
    begin
        if Args.Get('systemId', Tok) then
            if Tok.IsValue() then
                if Evaluate(SystemId, Tok.AsValue().AsText()) then;
    end;

    local procedure ResultText(Response: JsonObject) Text: Text
    var
        Tok: JsonToken;
    begin
        if Response.Get('value', Tok) then
            Tok.WriteTo(Text);
    end;

    local procedure EnrolledProcedures(CodeunitId: Integer) Suggest: JsonObject
    var
        Catalog: Record "Bcmag Procedure Catalog";
        Names: JsonArray;
    begin
        Catalog.SetRange("Logical Codeunit Id", CodeunitId);
        Catalog.SetRange("Allow Run", true);
        if Catalog.FindSet() then
            repeat
                Names.Add(Catalog."Procedure Name");
            until Catalog.Next() = 0;
        Suggest.Add('procedures', Names);
    end;

    [TryFunction]
    local procedure TryCoerceInt(Value: JsonValue; var Result: Integer)
    begin
        Result := Value.AsInteger();
    end;

    [TryFunction]
    local procedure TryCoerceText(Value: JsonValue; var Result: Text)
    begin
        Result := Value.AsText();
    end;
}
