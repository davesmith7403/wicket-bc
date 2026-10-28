codeunit 94141 "Bcmag Op Action"
{
    // "action" operation: run a named business action from the Action Catalog. A thin, discoverable,
    // security-aware front door over the invoke plane — the catalog row is the deny-by-default gate
    // (independent of raw-invoke exposure). The action's wrapper runs through the same single-instance
    // invoke context the invoke op uses, so any invoke wrapper is a provider.
    //
    // Two boundaries. A mutating verb runs its wrapper through Codeunit.Run, and a wrapper that succeeds
    // has its writes committed (a posting commits on its own anyway). A PREVIEW (data.preview = true, on
    // a verb with Preview Supported) and every verb enrolled with Is Mutating = false run inside the
    // forced rollback of Bcmag Action Rollback instead: explicit commits are ignored and every write is
    // rolled back (see that codeunit for the one thing a preview's wrapper must not do). That is why the
    // read-only switch and the key requirement let exactly those calls through (Bcmag Op Authorizer.RunsInRollback
    // holds the shared rule).
    //
    // data: { action, target?: { systemId }, args?: {...}, preview?: bool }
    //   target.systemId (from a query's @systemId) is merged into the wrapper args as `systemId`; an
    //   args.systemId that names a DIFFERENT record is refused (400) rather than silently preferred.
    //   args.preview is owned by the framework: data.preview = true always sets it to true, and a
    //   caller-supplied args.preview without data.preview = true is refused (400) — otherwise the
    //   Preview Supported gate is bypassed (args.preview:true on an unsupported action) or a
    //   preview request is turned into a real post (data.preview:true + args.preview:false).

    Access = Public;

    var
        JsonRead: Codeunit "Bcmag Json Read";
        Problem: Codeunit "Bcmag Problem";
        InvokeContext: Codeunit "Bcmag Invoke Context";

    procedure Run(Data: JsonObject; var Response: JsonObject; var Fail: JsonObject; var Cost: Integer): Boolean
    var
        Catalog: Record "Bcmag Action Catalog";
        Setup: Record "Bcmag Setup";
        Tok: JsonToken;
        ActionCode: Text;
        FailDetail: Text;
        Preview, InRollback : Boolean;
        MergedArgs: JsonObject;
        NoErrorTextLbl: Label 'the wrapper failed without an error message', Locked = true;
    begin
        Cost := 1;

        if not JsonRead.GetValue(Data, 'action', Tok) then begin
            Fail := Problem.NewFailure(400, 'missing-field', 'Missing action', 'data.action is required');
            exit(false);
        end;
        if not TryCoerceText(Tok.AsValue(), ActionCode) then begin
            Fail := Problem.NewFailure(400, 'invalid-field', 'Invalid action', 'data.action must be a string');
            exit(false);
        end;
        // Catalog.Get on a Code[50] key raises an overflow error for longer input (a 500); no such
        // action can be enrolled, so it is simply unknown.
        if StrLen(ActionCode) > MaxStrLen(Catalog."Action Code") then begin
            Fail := Problem.NewFailureSuggest(404, 'unknown-action', 'Unknown action',
                StrSubstNo('action code exceeds %1 characters, so it cannot be enrolled', MaxStrLen(Catalog."Action Code")), EnrolledActions());
            exit(false);
        end;

        if not Catalog.Get(ActionCode) then begin
            Fail := Problem.NewFailureSuggest(404, 'unknown-action', 'Unknown action',
                StrSubstNo('action "%1" is not enrolled', ActionCode), EnrolledActions());
            exit(false);
        end;
        if not Catalog."Allow Run" then begin
            Fail := Problem.NewFailure(403, 'action-disabled', 'Action disabled',
                StrSubstNo('action "%1" is enrolled but Allow Run is off', ActionCode));
            exit(false);
        end;

        if not GetOptionalBool(Data, 'preview', Preview) then begin
            Fail := Problem.NewFailure(400, 'invalid-field', 'Invalid preview', 'data.preview must be a boolean');
            exit(false);
        end;
        if Preview and not Catalog."Preview Supported" then begin
            Fail := Problem.NewFailure(400, 'preview-unsupported', 'Preview unsupported',
                StrSubstNo('action "%1" does not support preview', ActionCode));
            exit(false);
        end;

        // Defense in depth: the dispatcher's read-only master switch already refuses a mutating action
        // before this op runs, so this only fires if the op is reached by some other path. A preview or
        // a non-mutating verb runs inside the forced rollback and is allowed.
        InRollback := Preview or not Catalog."Is Mutating";
        Setup.GetSingleton();
        if Setup."Read-Only Mode" and not InRollback then begin
            Fail := Problem.NewFailure(403, 'read-only', 'Endpoint is read-only',
                StrSubstNo('action "%1" is disabled: the Wicket endpoint is in read-only mode', ActionCode));
            exit(false);
        end;

        if not BuildArgs(Data, Preview, MergedArgs, Fail) then
            exit(false);
        InvokeContext.SetArgs(MergedArgs);

        // Codeunit.Run isolates a wrapper error as a recoverable failure → 422 with the message.
        // ClearLastError first so a stale message from an earlier caught error is never reported as
        // the cause, and fall back to a fixed detail when the wrapper aborted without an error text.
        ClearLastError();
        if not RunWrapper(Catalog."Wrapper Codeunit Id", InRollback, not Preview) then begin
            FailDetail := GetLastErrorText();
            if FailDetail = '' then
                FailDetail := NoErrorTextLbl;
            Fail := Problem.NewFailure(422, 'action-failed', 'Action failed', FailDetail);
            exit(false);
        end;

        Clear(Response);
        if InvokeContext.HasResultValue() then
            Response.Add('value', InvokeContext.GetResult())
        else begin
            Clear(MergedArgs);
            MergedArgs.Add('ok', true);
            Response.Add('value', MergedArgs);
        end;
        exit(true);
    end;

    // True when the wrapper returned normally. In the forced rollback the boundary ALWAYS ends in the
    // sentinel error, so success is the context's completion mark, never Codeunit.Run's answer.
    local procedure RunWrapper(WrapperId: Integer; InRollback: Boolean; Guarded: Boolean): Boolean
    begin
        if not InRollback then
            exit(Codeunit.Run(WrapperId));
        InvokeContext.ArmRollback(WrapperId, Guarded);
        if Codeunit.Run(Codeunit::"Bcmag Action Rollback") then;
        exit(InvokeContext.IsRollbackCompleted());
    end;

    // Wrapper args = caller args, plus target.systemId flattened in and the preview flag, so a provider
    // reads one uniform args object (the same one the invoke op passes). Returns false (typed 400) only
    // when a scalar target.systemId fails text coercion; absent, null, or non-scalar values are skipped
    // (the wrapper then reports its own missing-systemId error).
    local procedure BuildArgs(Data: JsonObject; Preview: Boolean; var Args: JsonObject; var Fail: JsonObject): Boolean
    var
        Tok, SysTok, Existing: JsonToken;
        Serialized: Text;
        SystemIdText, ArgsSystemIdText: Text;
    begin
        Clear(Args);
        if Data.Get('args', Tok) then
            if Tok.IsObject() then begin
                Tok.AsObject().WriteTo(Serialized);
                Args.ReadFrom(Serialized);
            end else
                if not JsonRead.IsNull(Tok) then begin
                    // A string/array/number here is a client bug; dropping it silently would run the
                    // wrapper with defaults the caller never asked for.
                    Fail := Problem.NewFailure(400, 'invalid-field', 'Invalid args', 'data.args must be a JSON object');
                    exit(false);
                end;
        if Data.Get('target', Tok) and Tok.IsObject() then
            if Tok.AsObject().Get('systemId', SysTok) and JsonRead.IsNonNullValue(SysTok) then begin
                if not TryCoerceText(SysTok.AsValue(), SystemIdText) then begin
                    Fail := Problem.NewFailure(400, 'invalid-field', 'Invalid target', 'data.target.systemId must be a string');
                    exit(false);
                end;
                if Args.Get('systemId', Existing) then begin
                    // Two addresses for one action: if they disagree, which record the caller meant is
                    // unknowable — and the wrong guess posts the wrong document. Equal (as GUIDs) is fine.
                    ArgsSystemIdText := '';
                    if JsonRead.IsNonNullValue(Existing) then
                        if not TryCoerceText(Existing.AsValue(), ArgsSystemIdText) then
                            ArgsSystemIdText := '';
                    if NormalizeGuidText(ArgsSystemIdText) <> NormalizeGuidText(SystemIdText) then begin
                        Fail := Problem.NewFailure(400, 'invalid-field', 'Conflicting systemId',
                            'data.target.systemId and data.args.systemId name different records; send one of them');
                        exit(false);
                    end;
                end else
                    Args.Add('systemId', SystemIdText);
            end;
        // args.preview belongs to the framework (see the header comment).
        if Args.Get('preview', Existing) then begin
            if not Preview then begin
                Fail := Problem.NewFailure(400, 'invalid-field', 'Invalid args.preview',
                    'args.preview is reserved: request a preview with data.preview = true (the action must support preview)');
                exit(false);
            end;
            Args.Remove('preview');
        end;
        if Preview then
            Args.Add('preview', true);
        exit(true);
    end;

    local procedure NormalizeGuidText(Input: Text): Text
    begin
        exit(LowerCase(DelChr(Input, '<>', '{} ')));
    end;

    local procedure EnrolledActions() Suggest: JsonObject
    var
        Catalog: Record "Bcmag Action Catalog";
        Codes: JsonArray;
    begin
        Catalog.SetRange("Allow Run", true);
        if Catalog.FindSet() then
            repeat
                Codes.Add(LowerCase(Catalog."Action Code"));
            until Catalog.Next() = 0;
        Suggest.Add('actions', Codes);
    end;

    // Reads an optional boolean member. Absent or null → success with the default (false); present but
    // not coercible to a boolean → false, so the caller can answer with a typed 400 instead of letting
    // the JsonValue coercion error escape the op boundary as a generic 500.
    local procedure GetOptionalBool(Data: JsonObject; Name: Text; var Value: Boolean): Boolean
    var
        Tok: JsonToken;
    begin
        Value := false;
        if not Data.Get(Name, Tok) then
            exit(true);
        if not Tok.IsValue() then
            exit(false);
        if Tok.AsValue().IsNull() then
            exit(true);
        exit(TryCoerceBool(Tok.AsValue(), Value));
    end;

    [TryFunction]
    local procedure TryCoerceBool(Value: JsonValue; var Result: Boolean)
    begin
        Result := Value.AsBoolean();
    end;

    [TryFunction]
    local procedure TryCoerceText(Value: JsonValue; var Result: Text)
    begin
        Result := Value.AsText();
    end;
}
