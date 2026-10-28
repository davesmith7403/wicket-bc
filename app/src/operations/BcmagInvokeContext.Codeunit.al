codeunit 94123 "Bcmag Invoke Context"
{
    // Single-instance channel between the invoke handler and an enrolled wrapper codeunit.
    // A wrapper's OnRun reads GetArgs() and calls SetResult(). This keeps invoke generic
    // (Codeunit.Run by id) while only auditable, enrolled wrappers are ever callable.
    SingleInstance = true;

    var
        Args: JsonObject;
        Result: JsonObject;
        HasResult: Boolean;
        RollbackWrapperId: Integer;
        RollbackCompleted, RollbackGuarded : Boolean;

    procedure SetArgs(NewArgs: JsonObject)
    begin
        Args := NewArgs;
        Clear(Result);
        HasResult := false;
    end;

    procedure GetArgs(): JsonObject
    begin
        exit(Args);
    end;

    procedure SetResult(NewResult: JsonObject)
    begin
        Result := NewResult;
        HasResult := true;
    end;

    procedure GetResult(): JsonObject
    begin
        exit(Result);
    end;

    procedure HasResultValue(): Boolean
    begin
        exit(HasResult);
    end;

    // Forced-rollback channel (Bcmag Action Rollback): which wrapper to run, and whether it returned
    // normally before the sentinel rollback. Single-instance state survives the rollback.
    // Guarded = open a write transaction before the wrapper (non-mutating verbs; see Bcmag Action Rollback).
    procedure ArmRollback(WrapperId: Integer; Guarded: Boolean)
    begin
        RollbackWrapperId := WrapperId;
        RollbackGuarded := Guarded;
        RollbackCompleted := false;
    end;

    procedure IsRollbackGuarded(): Boolean
    begin
        exit(RollbackGuarded);
    end;

    procedure GetRollbackWrapperId(): Integer
    begin
        exit(RollbackWrapperId);
    end;

    procedure MarkRollbackCompleted()
    begin
        RollbackCompleted := true;
    end;

    procedure IsRollbackCompleted(): Boolean
    begin
        exit(RollbackCompleted);
    end;
}
