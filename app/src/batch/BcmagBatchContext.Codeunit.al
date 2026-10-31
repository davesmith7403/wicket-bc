codeunit 94162 "Bcmag Batch Context"
{
    // Carries a batch preview across its forced-rollback boundary (Bcmag Batch Rollback): the items going
    // in, and the results or the failing item's problem coming out. Single instance, so the values survive
    // the rollback that undoes every write the items made.
    SingleInstance = true;
    Access = Internal;

    var
        Items, Results : JsonArray;
        Fail: JsonObject;
        Completed, Failed : Boolean;

    procedure Arm(NewItems: JsonArray)
    begin
        Items := NewItems;
        Clear(Results);
        Clear(Fail);
        Completed := false;
        Failed := false;
    end;

    procedure GetItems(): JsonArray
    begin
        exit(Items);
    end;

    procedure SetCompleted(NewResults: JsonArray)
    begin
        Results := NewResults;
        Completed := true;
    end;

    procedure SetFailed(NewFail: JsonObject)
    begin
        Fail := NewFail;
        Failed := true;
    end;

    procedure IsCompleted(): Boolean
    begin
        exit(Completed);
    end;

    procedure IsFailed(): Boolean
    begin
        exit(Failed);
    end;

    procedure GetResults(): JsonArray
    begin
        exit(Results);
    end;

    procedure GetFail(): JsonObject
    begin
        exit(Fail);
    end;
}
