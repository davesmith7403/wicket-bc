codeunit 94125 "Bcmag Op Runner"
{
    // Executes one operation inside a Codeunit.Run boundary so that (a) an unhandled AL Error
    // is caught (Run() returns false) and converted to a 500 by the dispatcher, and (b) the
    // commits the write/invoke plane needs are permitted (a [TryFunction] would forbid them).

    var
        OpDiscover: Codeunit "Bcmag Op Discover";
        OpDescribe: Codeunit "Bcmag Op Describe";
        OpQuery: Codeunit "Bcmag Op Query";
        OpReadBlob: Codeunit "Bcmag Op Read Blob";
        OpCapabilities: Codeunit "Bcmag Op Capabilities";
        OpInsert: Codeunit "Bcmag Op Insert";
        OpModify: Codeunit "Bcmag Op Modify";
        OpDelete: Codeunit "Bcmag Op Delete";
        OpInvoke: Codeunit "Bcmag Op Invoke";
        OpStatus: Codeunit "Bcmag Op Status";
        OpCancel: Codeunit "Bcmag Async Cancel";
        OpRequests: Codeunit "Bcmag Op Requests";
        OpAction: Codeunit "Bcmag Op Action";
        OpSkill: Codeunit "Bcmag Op Skill";
        OpPageUrl: Codeunit "Bcmag Op Page Url";
        OpWhoAmI: Codeunit "Bcmag Op Who Am I";
        Problem: Codeunit "Bcmag Problem";
        Authorizer: Codeunit "Bcmag Op Authorizer";
        RollbackErr: Label 'Wicket: operation failed; partial writes rolled back', Locked = true;

    // No explicit Run() method: every codeunit with an OnRun trigger already exposes an
    // implicit instance Run(): Boolean that runs OnRun inside a Codeunit.Run boundary —
    // catching any unhandled AL Error (returns false) and committing on success. Declaring
    // our own Run() collided with that implicit method (AL0440). Callers use Runner.Run().

    trigger OnRun()
    var
        Ctx: Codeunit "Bcmag Op Runner Context";
        Response, Fail: JsonObject;
        Cost: Integer;
        OpOk: Boolean;
    begin
        OpOk := Dispatch(Ctx.GetOperation(), Ctx.GetData(), Response, Fail, Cost);
        Ctx.SetResult(OpOk, Response, Fail, Cost);
        // A failed operation must commit nothing. Returning normally would let the implicit
        // Codeunit.Run boundary COMMIT any write a handler performed before failing — e.g. a
        // table/field trigger or OnValidate side effect that a [TryFunction] (TryInsert/TryModify/
        // TryDelete, or the coercer's validate) caught but did NOT roll back. Raising an error here
        // makes the boundary roll those writes back. The failure itself is preserved in the
        // single-instance context (codeunit state survives the rollback) and read by the dispatcher.
        // Note: Error('') is a no-op in AL, so the sentinel message must be non-empty.
        if not OpOk then
            Error(RollbackErr);
    end;

    local procedure Dispatch(Operation: Text; Data: JsonObject; var Response: JsonObject; var Fail: JsonObject; var Cost: Integer): Boolean
    begin
        // Gates, enforced ahead of everything and BEFORE the handler: the read-only master switch (a
        // mutating call is refused before any table exposure, field policy or permission check can grant
        // it), then the role rung (a principal below the rung an operation needs gets a typed 403
        // role-forbidden with no side effects, instead of the platform's Execute denial escaping the Run
        // boundary as "500 internal"). The same gates guard an idempotency replay — one implementation,
        // in Bcmag Op Authorizer, so the two cannot drift apart.
        if not Authorizer.CheckGates(Operation, Data, Fail) then
            exit(false);

        case Operation of
            'discover':
                exit(OpDiscover.Run(Data, Response, Fail, Cost));
            'describe':
                exit(OpDescribe.Run(Data, Response, Fail, Cost));
            'query':
                exit(OpQuery.Run(Data, Response, Fail, Cost));
            'readBlob':
                exit(OpReadBlob.Run(Data, Response, Fail, Cost));
            'capabilities':
                exit(OpCapabilities.Run(Data, Response, Fail, Cost));
            'insert':
                exit(OpInsert.Run(Data, Response, Fail, Cost));
            'modify':
                exit(OpModify.Run(Data, Response, Fail, Cost));
            'delete':
                exit(OpDelete.Run(Data, Response, Fail, Cost));
            'invoke':
                exit(OpInvoke.Run(Data, Response, Fail, Cost));
            'status':
                exit(OpStatus.Run(Data, Response, Fail, Cost));
            'cancel':
                exit(OpCancel.Run(Data, Response, Fail, Cost));
            'requests':
                exit(OpRequests.Run(Data, Response, Fail, Cost));
            'action':
                exit(OpAction.Run(Data, Response, Fail, Cost));
            'skill':
                exit(OpSkill.Run(Data, Response, Fail, Cost));
            'pageUrl':
                exit(OpPageUrl.Run(Data, Response, Fail, Cost));
            'whoAmI':
                exit(OpWhoAmI.Run(Data, Response, Fail, Cost));
        end;
        Fail := Problem.NewFailureSuggest(404, 'unknown-operation', 'Unknown operation',
            StrSubstNo('"%1" is not a known operation', Operation), KnownOperationsSuggest());
        exit(false);
    end;

    local procedure KnownOperationsSuggest() Suggest: JsonObject
    var
        Ops: JsonArray;
    begin
        Ops.Add('discover');
        Ops.Add('describe');
        Ops.Add('query');
        Ops.Add('readBlob');
        Ops.Add('capabilities');
        Ops.Add('insert');
        Ops.Add('modify');
        Ops.Add('delete');
        Ops.Add('invoke');
        Ops.Add('status');
        Ops.Add('cancel');
        Ops.Add('requests');
        Ops.Add('action');
        Ops.Add('skill');
        Ops.Add('pageUrl');
        Ops.Add('whoAmI');
        Suggest.Add('operations', Ops);
    end;
}
