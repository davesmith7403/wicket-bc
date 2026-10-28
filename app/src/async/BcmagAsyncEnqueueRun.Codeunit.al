codeunit 94155 "Bcmag Async Enqueue Run"
{
    // Codeunit.Run boundary around the enqueue body (Bcmag Async Enqueuer.EnqueueCore), plus the
    // single-instance channel that carries its inputs and outcome across that boundary. TryEnqueue is
    // called by the dispatcher OUTSIDE the Op Runner's boundary, so an AL error raised while enqueueing
    // (a CreateTask refusal, an unexpected runtime fault) would otherwise escape the dispatcher and skip
    // its reservation release and audit row. Here any such error is caught (Run returns false) and
    // TryEnqueue turns it into a problem. The state survives the rollback because it lives in this
    // single instance, not in the transaction — including the Entry No. of a row that was already
    // committed, which TryEnqueue then marks Failed rather than leaving it without a worker.

    Access = Internal;
    SingleInstance = true;

    var
        Operation, RequestId, Origin, IdempotencyKey : Text;
        Data, Result, Fail : JsonObject;
        Accepted, HasResult : Boolean;
        CommittedEntryNo: BigInteger;

    trigger OnRun()
    var
        Enqueuer: Codeunit "Bcmag Async Enqueuer";
        NewResult, NewFail : JsonObject;
        Ok: Boolean;
    begin
        Ok := Enqueuer.EnqueueCore(Operation, Data, RequestId, Origin, IdempotencyKey, NewResult, NewFail);
        Accepted := Ok;
        Result := NewResult;
        Fail := NewFail;
        HasResult := true;
    end;

    procedure SetRequest(NewOperation: Text; NewData: JsonObject; NewRequestId: Text; NewOrigin: Text; NewIdempotencyKey: Text)
    begin
        Operation := NewOperation;
        Data := NewData;
        RequestId := NewRequestId;
        Origin := NewOrigin;
        IdempotencyKey := NewIdempotencyKey;
        Clear(Result);
        Clear(Fail);
        Accepted := false;
        HasResult := false;
        CommittedEntryNo := 0;
    end;

    // Called by EnqueueCore right after the queue row is committed.
    procedure NoteCommitted(EntryNo: BigInteger)
    begin
        CommittedEntryNo := EntryNo;
    end;

    procedure GetHasResult(): Boolean
    begin
        exit(HasResult);
    end;

    procedure GetAccepted(): Boolean
    begin
        exit(Accepted);
    end;

    procedure GetResult(): JsonObject
    begin
        exit(Result);
    end;

    procedure GetFail(): JsonObject
    begin
        exit(Fail);
    end;

    procedure GetCommittedEntryNo(): BigInteger
    begin
        exit(CommittedEntryNo);
    end;
}
