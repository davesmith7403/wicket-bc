codeunit 94100 "Bcmag Rpc Dispatcher"
{
    // Single place for cross-cutting concerns: envelope validation, operation routing,
    // error isolation, durable logging, and Application Insights telemetry.
    //
    // Operation execution runs through Codeunit.Run("Bcmag Op Runner"), which (a) turns an
    // unhandled AL Error into a recoverable failure (we synthesise a 500 instead of leaking
    // a raw stack trace) and (b) permits the commits that the write/invoke plane needs —
    // both of which a [TryFunction] could not do.
    //
    // v1 transport: ALWAYS returns HTTP 200 with a JSON body. On success the body is the
    // operation result; on failure it is a complete RFC 7807 problem document. We never call
    // Error(), so the end-of-request log Insert always commits — including for failed calls.

    var
        JsonRead: Codeunit "Bcmag Json Read";
        Envelope: Codeunit "Bcmag Envelope";
        Logger: Codeunit "Bcmag Logger";
        Problem: Codeunit "Bcmag Problem";
        AsyncEnqueuer: Codeunit "Bcmag Async Enqueuer";
        Guard: Codeunit "Bcmag Idempotency Guard";
        Authorizer: Codeunit "Bcmag Op Authorizer";
        // The current request's data, for the audit row (table, target, request details). Set once the
        // envelope parses and cleared at every request start: one dispatcher instance serves many calls.
        AuditData: JsonObject;
        TelemetryEventIdTok: Label 'WICKET-0001', Locked = true;

    procedure Run(Operation: Text; Body: JsonObject; IdempotencyKey: Text): JsonObject
    var
        Status: Integer;
    begin
        exit(RunEx(Operation, Body, IdempotencyKey, Status));
    end;

    // The wire entry point. The platform publishes an API page's [ServiceEnabled] procedure as an OData
    // bound action only for simple parameter and return types — a JsonObject parameter compiles clean
    // and is silently left out of $metadata. So the envelope crosses the wire as one JSON string
    // ({"envelope":"<json>"}) and the result comes back as one JSON string ({"value":"<json>"}).
    // Text that is not a JSON object is answered like any malformed envelope: a 400 problem, audited.
    procedure RunText(Operation: Text; EnvelopeText: Text): Text
    var
        Body, Result, Fail: JsonObject;
        StartedAt: DateTime;
        ResultText: Text;
    begin
        if Body.ReadFrom(EnvelopeText) then
            Result := Run(Operation, Body, '')
        else begin
            StartedAt := CurrentDateTime();
            Fail := Problem.NewFailure(400, 'invalid-envelope', 'Invalid envelope',
                'the "envelope" parameter must be a string holding one JSON object (the envelope serialised: {"id":…,"issuedAt":…,"origin":…,"data":{…}})');
            Result := Problem.FromFailure(Fail, Operation, '');
            Clear(AuditData);
            FinishRequest('', '', Operation, '', UserId(), 400, 0, StartedAt,
                Problem.ProblemTypeOf(Fail), Problem.DetailOf(Fail));
        end;
        Result.WriteTo(ResultText);
        exit(ResultText);
    end;

    // RunEx surfaces the logical HTTP status for in-process callers (tests, conformance).
    // Over the wire the status lives only in the body (Problem.status); the HTTP status is
    // always 200 because a bound action cannot set an arbitrary status code.
    procedure RunEx(Operation: Text; Body: JsonObject; IdempotencyKey: Text; var Status: Integer) Result: JsonObject
    var
        Runner: Codeunit "Bcmag Op Runner";
        RunnerCtx: Codeunit "Bcmag Op Runner Context";
        Id, Origin, Caller, ErrorMsg, ProblemType, ProblemDetail: Text;
        EnvelopeKey, BodyHash, StoredHash, ResultText: Text;
        IssuedAt, StartedAt: DateTime;
        Data, Fail: JsonObject;
        Cost: Integer;
        OpOk, NoAlError, Reserved, Retryable: Boolean;
    begin
        StartedAt := CurrentDateTime();
        Caller := UserId();
        Status := 200;
        Cost := 0;
        Clear(AuditData);

        if not Envelope.Parse(Body, Id, IssuedAt, Origin, Data, EnvelopeKey, ErrorMsg) then begin
            // No idempotency-table write on this path: a request that failed envelope validation
            // has no trusted key or body to anchor a replay on, and caching its 400 would mask
            // the caller's corrected retry. The audit row still records the parameter-passed key.
            Fail := Problem.NewFailure(400, 'invalid-envelope', 'Invalid envelope', ErrorMsg);
            Result := Problem.FromFailure(Fail, Operation, '');
            Status := 400;
            FinishRequest(Id, IdempotencyKey, Operation, Origin, Caller, Status, 0, StartedAt,
                Problem.ProblemTypeOf(Fail), ErrorMsg);
            exit(Result);
        end;

        AuditData := Data;

        // The envelope is the wire-level carrier (a bound action cannot read HTTP headers);
        // the parameter stays as a fallback for in-process callers.
        if EnvelopeKey <> '' then
            IdempotencyKey := EnvelopeKey;

        // The request scope begins HERE, before anything consults the field policy: the replay
        // authorization below, the async enqueue's checks and the runner all read this request's
        // "unmask" flag, judge under a fresh policy generation, and note lifts against this request's
        // list (which the Operation Log records). Set later, a replay would be authorized under the
        // PREVIOUS request's flag — a caller's "unmask": false opt-out ignored exactly when it matters.
        // Only the 400 envelope refusal above precedes it; it reads no policy and logs no lifts.
        RunnerCtx.SetRequest(Operation, Data);
        RunnerCtx.SetEnvelope(Id, Origin);

        // Posting through a wrapper COMMITS; without a key, a caller that loses the response (timeout,
        // dropped connection) cannot find out whether it took effect except by reconciling business
        // records, and the natural retry posts twice. Tenants can require a key for the two operations
        // that reach wrappers (action, and invoke — the same wrappers are enrolled there too). Refused
        // before any reservation or execution and never snapshotted: there is no key to store it under.
        if (IdempotencyKey = '') and KeyRequired(Operation, Data) then begin
            Fail := Problem.NewFailure(400, 'idempotency-key-required', 'Idempotency key required',
                StrSubstNo('operation "%1" requires an idempotencyKey on this tenant (Wicket Setup "Require Key For Actions"): a wrapper may post and commit, and only a key lets a lost response be retried safely. Send a fresh unique key per logical request and reuse it for retries.', Operation));
            Result := Problem.FromFailure(Fail, Operation, Id);
            Status := 400;
            FinishRequest(Id, IdempotencyKey, Operation, Origin, Caller, Status, 0, StartedAt,
                Problem.ProblemTypeOf(Fail), Problem.DetailOf(Fail));
            exit(Result);
        end;

        if IdempotencyKey <> '' then begin
            BodyHash := CanonicalHash(Operation, Data);
            if TryReplay(IdempotencyKey, BodyHash, Id, Operation, Data, Origin, Caller, StartedAt, Result, Status) then
                exit(Result);

            // No usable snapshot: take the EXECUTION reservation (committed) before running anything.
            // The snapshot alone is a replay cache — two identical requests that both miss it would
            // both execute, and a crash between the business commit and the snapshot would let a retry
            // run the operation again. The reservation's outcome decides:
            case Guard.Reserve(IdempotencyKey, BodyHash, Id, StoredHash) of
                "Bcmag Reservation Outcome"::Reserved:
                    Reserved := true;
                "Bcmag Reservation Outcome"::Conflict:
                    Fail := ConflictFailure(IdempotencyKey);
                "Bcmag Reservation Outcome"::"In Progress":
                    if StoredHash <> BodyHash then
                        Fail := ConflictFailure(IdempotencyKey)
                    else
                        Fail := Problem.NewFailure(409, 'idempotency-in-progress', 'Request already in progress',
                            StrSubstNo('idempotency key ''%1'' is being executed by an earlier request that has not finished; wait, then retry with the same key to receive its result', IdempotencyKey));
                "Bcmag Reservation Outcome"::Completed:
                    begin
                        // Settled, yet no snapshot a moment ago: it may have landed between the two
                        // lookups — check once more. Otherwise the earlier outcome is unknowable here
                        // (its best-effort snapshot never landed), and re-executing is exactly the
                        // duplicate the key was meant to prevent.
                        if TryReplay(IdempotencyKey, BodyHash, Id, Operation, Data, Origin, Caller, StartedAt, Result, Status) then
                            exit(Result);
                        Fail := IndeterminateFailure(IdempotencyKey);
                    end;
                "Bcmag Reservation Outcome"::Stale:
                    if StoredHash <> BodyHash then
                        Fail := ConflictFailure(IdempotencyKey)
                    else
                        Fail := IndeterminateFailure(IdempotencyKey);
            end;
            if not Reserved then begin
                Status := 409;
                Result := Problem.FromFailure(Fail, Operation, Id);
                FinishRequest(Id, IdempotencyKey, Operation, Origin, Caller, Status, 0, StartedAt,
                    Problem.ProblemTypeOf(Fail), Problem.DetailOf(Fail));
                exit(Result);
            end;
        end;

        // Async delivery fork: a request carrying a "deliver" block is ENQUEUED (a durable write) and
        // a background worker produces the package later, instead of running inline. This sits AFTER the
        // idempotency replay/conflict block so a duplicate deliver with the same key REPLAYS the identical
        // @async accepted response (same requestId) without enqueueing twice. The enqueue outcome reuses
        // the existing idempotency-snapshot + FinishRequest tail below, so it audits and replays exactly
        // like any other result. Transport stays always-200: a successful enqueue is a success (logical
        // Status 200 with the @async body), not a problem. The non-deliver path is untouched.
        if AsyncEnqueuer.HasDeliver(Data) then begin
            if AsyncEnqueuer.TryEnqueue(Operation, Data, Id, Origin, IdempotencyKey, Result, Fail) then begin
                Status := 200;
                Result.Add('@requestId', Id);
            end else begin
                Status := Problem.StatusOf(Fail);
                ProblemType := Problem.ProblemTypeOf(Fail);
                ProblemDetail := Problem.DetailOf(Fail);
                Result := Problem.FromFailure(Fail, Operation, Id);
            end;

            Retryable := IsPreExecutionRefusal(Status, ProblemType);
            if (IdempotencyKey <> '') and (Status < 500) and not Retryable then begin
                // The accepted response carries packageUrl. When a download mode signs it, the query
                // string IS a bearer credential (SAS) — the idempotency log must not become a long-lived
                // store of live tokens. The snapshot keeps the bare blob URL; a replay therefore hands out
                // a tokenless URL, and the caller gets a freshly signed one from `status` (which re-mints
                // on every call) — the same thing a scheduled request already does.
                SnapshotWithoutUrlToken(Result).WriteTo(ResultText);
                Logger.LogIdempotencyResponse(IdempotencyKey, Id, BodyHash, Operation, Status, ResultText);
            end;
            Settle(Reserved, IdempotencyKey, Status, Retryable);
            FinishRequest(Id, IdempotencyKey, Operation, Origin, Caller, Status, Cost, StartedAt, ProblemType, ProblemDetail);
            exit(Result);
        end;

        // The runner reads Operation/Data from the context set at the top of this request.
        NoAlError := Runner.Run(); // Codeunit.Run boundary lives inside; returns true only if no AL error escaped
        RecordFailedRun();

        // On failure the runner deliberately raises an error so the boundary rolls its writes back
        // (a problem document must never leave partial writes committed). The outcome survives in the
        // single-instance context, so a stashed result is authoritative whether or not an error was
        // raised. Only the ABSENCE of a stashed result means an unexpected AL error escaped before the
        // handler could record one — that becomes a 500.
        if NoAlError or RunnerCtx.GetHasResult() then begin
            OpOk := RunnerCtx.GetOpOk();
            Cost := RunnerCtx.GetCost();
            if OpOk then
                Result := RunnerCtx.GetResponse()
            else
                Fail := RunnerCtx.GetFail();
        end else
            Fail := Problem.NewFailure(500, 'internal', 'Internal error', GetLastErrorText());

        // Commit-time failure: the handler finished and stashed a SUCCESS, but the Run boundary still
        // returned false — its closing commit (or something after SetResult) failed, so every write
        // was rolled back. The stashed response describes an effect that did not persist, and the empty
        // Fail would otherwise default to a 400 with no type that gets cached and settles the key. It is
        // an internal failure: 500 (never snapshotted; see the Settle below for action/invoke) with the platform's text.
        if (not NoAlError) and OpOk then
            Fail := Problem.NewFailure(500, 'internal', 'Internal error',
                StrSubstNo('the operation completed but its changes could not be committed, so none of them took effect: %1', GetLastErrorText()));

        if NoAlError and OpOk then begin
            Status := 200;
            Result.Add('@requestId', Id);
        end else begin
            Status := Problem.StatusOf(Fail);
            ProblemType := Problem.ProblemTypeOf(Fail);
            ProblemDetail := Problem.DetailOf(Fail);
            Result := Problem.FromFailure(Fail, Operation, Id);
        end;

        // Snapshot only FINAL outcomes: 2xx/4xx replay verbatim on retry, but a 5xx must stay
        // retryable (the next attempt may succeed), so it is never stored. Neither is a refusal that
        // was raised before anything executed and that an administrator (or time) can lift — see
        // IsPreExecutionRefusal. The logger write is [TryFunction]-guarded — a failed snapshot insert
        // cannot void the completed operation.
        Retryable := IsPreExecutionRefusal(Status, ProblemType);
        if (IdempotencyKey <> '') and (Status < 500) and not Retryable then begin
            SnapshotWithoutUrlToken(Result).WriteTo(ResultText);
            Logger.LogIdempotencyResponse(IdempotencyKey, Id, BodyHash, Operation, Status, ResultText);
        end;
        // action/invoke run wrappers that COMMIT inside the Run boundary (Sales-Post commits several
        // times). A 5xx there — the closing commit failing after the handler succeeded, or an error
        // after the wrapper returned — can follow an effect that already persisted, so releasing the
        // key would let the faithful same-key retry post a second time. Settle it instead (no snapshot):
        // the retry gets 409 idempotency-indeterminate and is told to verify before using a new key.
        // Pre-execution refusals are raised ahead of the wrapper and stay releasable.
        // A preview or non-mutating verb ran inside the forced rollback: nothing can have persisted.
        // The same uncertainty belongs in the change history: the wrapper may have committed, and the
        // success entry it wrote inside the boundary was rolled back with everything else.
        if (Status >= 500) and (Operation in ['action', 'invoke']) and not Retryable and Authorizer.IsMutatingRequest(Operation, Data) then begin
            RecordRunAfterFailure(Operation, Data, ProblemDetail);
            Settle(Reserved, IdempotencyKey, 200, false);
        end else
            Settle(Reserved, IdempotencyKey, Status, Retryable);

        FinishRequest(Id, IdempotencyKey, Operation, Origin, Caller, Status, Cost, StartedAt, ProblemType, ProblemDetail);
        exit(Result);
    end;

    // Snapshot lookup for a key. True when it produced a FINAL answer in Result/Status: a verbatim
    // replay (same body), a 409 idempotency-conflict (same key, other body), or a refusal because the
    // caller may no longer receive the stored response. False when there is no usable snapshot for this
    // caller + key — the caller then reserves and executes.
    local procedure TryReplay(IdempotencyKey: Text; BodyHash: Text; Id: Text; Operation: Text; Data: JsonObject; Origin: Text; Caller: Text; StartedAt: DateTime; var Result: JsonObject; var Status: Integer): Boolean
    var
        Stored, Fail: JsonObject;
        StoredHash, StoredResponse, ProblemType, ProblemDetail: Text;
        StoredStatus: Integer;
    begin
        if not Logger.FindReplay(IdempotencyKey, StoredHash, StoredStatus, StoredResponse) then
            exit(false);
        if StoredHash = BodyHash then begin
            // Same key, same body: replay the stored outcome verbatim (it still carries the ORIGINAL
            // @requestId/instance) without executing. The replay itself is audited through the normal
            // FinishRequest path. An unparseable snapshot is reported as "no snapshot"; the reservation
            // then decides whether execution is safe (it is not once that key has settled).
            if not Stored.ReadFrom(StoredResponse) then
                exit(false);
            // Same caller, same key, same body — but the same RIGHTS? Caller scoping stops another
            // principal from replaying this key; it says nothing about this principal having since lost
            // the role, table, permission or field access that produced the response. Authorization is
            // evaluated at every disclosure: the snapshot is judged against the policy in force now and
            // refused with the problem the operation itself would return today. The refusal is not
            // stored; the snapshot stays, and replays again once access is restored.
            if not Authorizer.AuthorizeReplay(Operation, Data, Stored, Fail) then begin
                // The stored outcome is FINAL — the request completed (a write took effect, a posting
                // committed). Answering with the plain refusal a fresh call would get ("403 read-only",
                // "403 not-exposed") tells the client the request never happened, and the natural
                // reaction is to repeat it under a new key: a duplicate write. So the refusal says what
                // is true — it completed with status N, and only its CONTENT is withheld, for <reason>.
                // Only a stored SUCCESS is an effect that must not be repeated. A stored 4xx (a malformed
                // request, a missing record, a rolled-back business failure) took no effect, so claiming
                // it "completed" would talk the client out of a write that never happened; it gets the
                // plain refusal a fresh call would get.
                if (StoredStatus >= 200) and (StoredStatus < 300) then
                    Fail := ReplayWithheld(IdempotencyKey, StoredStatus, Fail);
                Status := Problem.StatusOf(Fail);
                Result := Problem.FromFailure(Fail, Operation, Id);
                FinishRequest(Id, IdempotencyKey, Operation, Origin, Caller, Status, 0, StartedAt,
                    Problem.ProblemTypeOf(Fail), Problem.DetailOf(Fail));
                exit(true);
            end;
            Result := Stored;
            Result.Add('@replayed', true);
            Status := StoredStatus;
            if Status >= 400 then begin
                ProblemType := JsonMemberText(Result, 'type');
                ProblemDetail := JsonMemberText(Result, 'detail');
            end;
            FinishRequest(Id, IdempotencyKey, Operation, Origin, Caller, Status, 0, StartedAt, ProblemType, ProblemDetail);
            exit(true);
        end;
        // Same key + same caller, but a different business payload (different data OR a different
        // operation — both change the hash): the caller broke the idempotency contract. Scoped to
        // this principal, so it can never collide with another user.
        Fail := ConflictFailure(IdempotencyKey);
        Status := 409;
        Result := Problem.FromFailure(Fail, Operation, Id);
        FinishRequest(Id, IdempotencyKey, Operation, Origin, Caller, Status, 0, StartedAt,
            Problem.ProblemTypeOf(Fail), Problem.DetailOf(Fail));
        exit(true);
    end;

    local procedure ConflictFailure(IdempotencyKey: Text): JsonObject
    begin
        exit(Problem.NewFailure(409, 'idempotency-conflict', 'Idempotency conflict',
            StrSubstNo('idempotency key ''%1'' was already used with a different request body', IdempotencyKey)));
    end;

    local procedure IndeterminateFailure(IdempotencyKey: Text): JsonObject
    begin
        exit(Problem.NewFailure(409, 'idempotency-indeterminate', 'Earlier outcome unknown',
            StrSubstNo('an earlier request with idempotency key ''%1'' started but never recorded an outcome, so it may or may not have taken effect; verify the business result (query the affected records) before retrying with a NEW key. Retrying with the same key will keep returning this problem.', IdempotencyKey)));
    end;

    // Final outcomes (2xx/4xx) settle the reservation so the key can never execute again; a 5xx, or a
    // pre-execution refusal that can be lifted, releases it so the next attempt may run. Mirrors which
    // outcomes get a snapshot.
    local procedure Settle(Reserved: Boolean; IdempotencyKey: Text; Status: Integer; Retryable: Boolean)
    begin
        if not Reserved then
            exit;
        if (Status < 500) and not Retryable then
            Guard.Complete(IdempotencyKey)
        else
            Guard.Release(IdempotencyKey);
    end;

    // A refusal raised BEFORE anything executed, for a reason outside the request itself that an
    // administrator or the passage of time can lift: the tenant's read-only switch, the caller's role
    // rung, an exposure/catalog gate that is off, async not configured yet, backpressure. Caching one
    // as the key's final answer would burn the key — the caller's faithful retry with the SAME key
    // after the admin fixes the gate would replay the refusal forever. Every one of these is raised by
    // a gate that runs ahead of the handler's business effect (and a failed runner call rolls back
    // anyway), so releasing the reservation cannot let a completed effect run twice. A malformed
    // request (400), a missing record (404) or a business failure (422 — a posting may have
    // committed) stays final.
    procedure IsPreExecutionRefusal(Status: Integer; ProblemType: Text): Boolean
    var
        Slug: Text;
    begin
        if (Status < 400) or (Status >= 500) then
            exit(false);
        foreach Slug in PreExecutionRefusals() do
            if ProblemType = Problem.TypeUri(Slug) then
                exit(true);
        exit(false);
    end;

    local procedure PreExecutionRefusals() Slugs: List of [Text]
    begin
        Slugs.Add('too-many-requests');      // 429 async backpressure
        Slugs.Add('read-only');              // 403 tenant switch (runner gate)
        Slugs.Add('role-forbidden');         // 403 role rung (runner gate)
        Slugs.Add('async-not-configured');   // 403 async setup incomplete
        Slugs.Add('not-exposed');            // 403 exposure allowlist / BC permission, checked before the handler acts
        Slugs.Add('action-disabled');        // 403 Action Catalog Allow Run off
        Slugs.Add('invoke-disabled');        // 403 Procedure Catalog Allow Run off
        Slugs.Add('trigger-bypass-disabled'); // 403 tenant policy, checked before the write
    end;

    local procedure ReplayWithheld(IdempotencyKey: Text; StoredStatus: Integer; Reason: JsonObject) Fail: JsonObject
    var
        ReasonSlug: Text;
    begin
        ReasonSlug := Problem.ProblemTypeOf(Reason);
        if ReasonSlug.StartsWith(Problem.TypeUri('')) then
            ReasonSlug := CopyStr(ReasonSlug, StrLen(Problem.TypeUri('')) + 1);
        Fail := Problem.NewFailure(403, 'replay-withheld', 'Replay withheld',
            StrSubstNo('the original request with idempotency key ''%1'' COMPLETED with status %2 — its outcome is final and it must NOT be repeated under a new key. Only its stored response is withheld, because of %3: %4. The same key replays it again once access is restored.',
                IdempotencyKey, StoredStatus, ReasonSlug, Problem.DetailOf(Reason)));
        Fail.Add('originalStatus', StoredStatus);
        Fail.Add('reason', ReasonSlug);
    end;

    // Copy of a response with the query string (the SAS token) cut off every packageUrl, wherever it
    // sits — the async accepted body and a status/requests projection alike. The idempotency log is
    // readable by the Audit role across callers; a live signed URL there would hand another caller's
    // export to anyone who can read the log. A replay gets the bare URL; status re-signs on demand.
    local procedure SnapshotWithoutUrlToken(Response: JsonObject) Snapshot: JsonObject
    var
        Serialized: Text;
        Tok: JsonToken;
    begin
        Response.WriteTo(Serialized);
        Snapshot.ReadFrom(Serialized);
        Tok := Snapshot.AsToken();
        StripUrlTokens(Tok);
    end;

    local procedure StripUrlTokens(Tok: JsonToken)
    var
        Obj: JsonObject;
        Arr: JsonArray;
        Child: JsonToken;
        Name, Url: Text;
    begin
        if Tok.IsArray() then begin
            Arr := Tok.AsArray();
            foreach Child in Arr do
                StripUrlTokens(Child);
            exit;
        end;
        if not Tok.IsObject() then
            exit;
        Obj := Tok.AsObject();
        foreach Name in Obj.Keys() do begin
            Obj.Get(Name, Child);
            if (Name = 'packageUrl') and JsonRead.IsNonNullValue(Child) then begin
                Url := Child.AsValue().AsText();
                if StrPos(Url, '?') > 0 then
                    Obj.Replace(Name, CopyStr(Url, 1, StrPos(Url, '?') - 1));
            end else
                StripUrlTokens(Child);
        end;
    end;

    // A preview or a non-mutating verb runs inside the forced rollback (Bcmag Action Rollback): nothing
    // can take effect, so there is nothing a key would protect against repeating.
    local procedure KeyRequired(Operation: Text; Data: JsonObject): Boolean
    var
        Setup: Record "Bcmag Setup";
    begin
        if not (Operation in ['action', 'invoke']) then
            exit(false);
        if not Authorizer.IsMutatingRequest(Operation, Data) then
            exit(false);
        Setup.GetSingleton();
        exit(Setup."Require Key For Actions");
    end;

    // Replay-identity scheme (operation-in-hash, caller-scoped rows), shared by the snapshot and the
    // reservation:
    //   identity = (Caller, Idempotency Key, operation, data)
    // The hash covers ONLY the canonical business payload {operation, data}, deliberately
    // EXCLUDING volatile envelope metadata (id/@requestId, issuedAt, origin, idempotencyKey)
    // that legitimately changes on every retry. So a faithful client that retries with the same
    // key + operation + data but a FRESH request id now REPLAYS instead of hitting a spurious 409.
    // Operation is folded INTO the hash rather than a separate SetRange (one coherent place for
    // it): FindReplay matches rows by (Caller, Idempotency Key), then compares this hash. Because
    // operation is inside the hash, reusing a key for a different operation yields a different hash
    // and surfaces as a 409 conflict — acceptable and safe, since an idempotency key is a promise
    // of a single logical request. Relaxing the hash to the payload does not widen exposure:
    // cross-principal replay is already blocked by the Caller = UserSecurityId() row scoping.
    procedure CanonicalHash(Operation: Text; Data: JsonObject): Text
    var
        CryptographyMgt: Codeunit "Cryptography Management";
        HashAlgorithm: Option MD5,SHA1,SHA256,SHA384,SHA512;
        Canonical: JsonObject;
        BodyText: Text;
    begin
        Canonical.Add('operation', Operation);
        Canonical.Add('data', Data);
        Canonical.WriteTo(BodyText);
        exit(CryptographyMgt.GenerateHash(BodyText, HashAlgorithm::SHA256));
    end;

    local procedure JsonMemberText(Obj: JsonObject; Name: Text): Text
    var
        Tok: JsonToken;
    begin
        if Obj.Get(Name, Tok) then
            if JsonRead.IsNonNullValue(Tok) then
                exit(Tok.AsValue().AsText());
        exit('');
    end;

    // A mutating action or procedure that failed may have committed before it failed; the boundary
    // rolled back the request's own writes, so its change history entry is written here, outside it.
    local procedure RecordFailedRun()
    var
        RunnerCtx: Codeunit "Bcmag Op Runner Context"; // single instance: the request's context
        Recorder: Codeunit "Bcmag Change Recorder";
        Kind: Enum "Bcmag Change Kind";
        Name, Detail: Text;
        SystemId: Guid;
    begin
        if RunnerCtx.TakeFailedRun(Kind, Name, SystemId, Detail) then
            Recorder.RecordRun(Kind, Name, 0, SystemId, Recorder.FailedOutcome(), Detail);
    end;

    // A mutating action or invoke that ended in a 5xx after its wrapper may have committed: one
    // "Failed - may have changed data" entry, named and targeted from the request itself.
    local procedure RecordRunAfterFailure(Operation: Text; Data: JsonObject; Detail: Text)
    var
        Recorder: Codeunit "Bcmag Change Recorder";
        Tok: JsonToken;
        Kind: Enum "Bcmag Change Kind";
        Name: Text;
        SystemId: Guid;
    begin
        if Operation = 'action' then begin
            Kind := Kind::Action;
            if Data.Get('action', Tok) then
                if Tok.IsValue() then
                    Name := Tok.AsValue().AsText();
        end else begin
            Kind := Kind::ProcedureRun;
            if Data.Get('codeunitId', Tok) then
                if Tok.IsValue() then
                    Name := Tok.AsValue().AsText();
            if Data.Get('procedure', Tok) then
                if Tok.IsValue() then
                    Name += '.' + Tok.AsValue().AsText();
        end;
        if not TargetSystemIdOf(Data, 'target', SystemId) then
            if TargetSystemIdOf(Data, 'args', SystemId) then;
        Recorder.RecordRun(Kind, Name, 0, SystemId, Recorder.FailedOutcome(), Detail);
    end;

    local procedure TargetSystemIdOf(Data: JsonObject; Member: Text; var SystemId: Guid): Boolean
    var
        Tok: JsonToken;
    begin
        if not Data.Get(Member, Tok) then
            exit(false);
        if not Tok.IsObject() then
            exit(false);
        if not Tok.AsObject().Get('systemId', Tok) then
            exit(false);
        if not Tok.IsValue() then
            exit(false);
        exit(Evaluate(SystemId, Tok.AsValue().AsText()));
    end;

    local procedure FinishRequest(Id: Text; IdempotencyKey: Text; Operation: Text; Origin: Text; Caller: Text; Status: Integer; Cost: Integer; StartedAt: DateTime; ProblemType: Text; ProblemDetail: Text)
    var
        EndedAt: DateTime;
        DurationMs: Integer;
    begin
        EndedAt := CurrentDateTime();
        DurationMs := EndedAt - StartedAt;
        Logger.Write(Id, IdempotencyKey, Operation, Origin, Caller, Status, Cost, DurationMs, ProblemType, ProblemDetail, StartedAt, EndedAt, AuditData);
        EmitTelemetry(Operation, Origin, Status, Cost, DurationMs, ProblemType);
    end;

    local procedure EmitTelemetry(Operation: Text; Origin: Text; Status: Integer; Cost: Integer; DurationMs: Integer; ProblemType: Text)
    var
        Dimensions: Dictionary of [Text, Text];
        Verbosity: Verbosity;
    begin
        Dimensions.Add('operation', Operation);
        Dimensions.Add('status', Format(Status));
        Dimensions.Add('origin', Origin);
        Dimensions.Add('cost', Format(Cost));
        Dimensions.Add('durationMs', Format(DurationMs));
        if ProblemType <> '' then
            Dimensions.Add('problemType', ProblemType);

        case true of
            Status >= 500:
                Verbosity := Verbosity::Error;
            Status >= 400:
                Verbosity := Verbosity::Warning;
            else
                Verbosity := Verbosity::Normal;
        end;

        Session.LogMessage(TelemetryEventIdTok, StrSubstNo('Wicket %1 -> %2', Operation, Status),
            Verbosity, DataClassification::SystemMetadata, TelemetryScope::ExtensionPublisher, Dimensions);
    end;
}
