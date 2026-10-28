codeunit 94146 "Bcmag Role Gate"
{
    // Per-principal operation policy, answered by the platform. Each Wicket rung grants full write
    // rights on one empty sentinel table ("Bcmag Execute Gate" from Execute up, "Bcmag Write Gate" from
    // Edit up); Record.WritePermission on that table is therefore "is the caller on this rung or above",
    // independent of whatever else the principal holds — a `codeunit * = X` wildcard, a business-table
    // write set, SUPER. Checked before a handler runs so a refusal is a clean 403 role-forbidden with no
    // side effects, rather than the platform's Execute denial escaping the Run boundary as 500 internal.
    //
    // Deliberately NOT text-matching the platform's permission error (localized, brittle) and NOT turning
    // every runtime error into a 403: only this pre-check answers 403; unrelated failures stay 500.

    Access = Public;

    var
        Problem: Codeunit "Bcmag Problem";

    // False + Fail when the caller lacks the rung an operation needs. Read-plane operations need no gate:
    // any Wicket rung may run them (the Op codeunits' own Execute grants still apply).
    procedure CheckOperation(Operation: Text; var Fail: JsonObject): Boolean
    var
        ExecuteGate: Record "Bcmag Execute Gate";
        WriteGate: Record "Bcmag Write Gate";
    begin
        case true of
            Operation in ['invoke', 'action']:
                if not ExecuteGate.WritePermission() then begin
                    Fail := Refusal(Operation, 'Wicket - Execute');
                    exit(false);
                end;
            Operation in ['insert', 'modify', 'delete']:
                if not WriteGate.WritePermission() then begin
                    Fail := Refusal(Operation, 'Wicket - Edit');
                    exit(false);
                end;
        end;
        exit(true);
    end;

    local procedure Refusal(Operation: Text; RequiredRole: Text) Fail: JsonObject
    begin
        Fail := Problem.NewFailure(403, 'role-forbidden', 'Operation not permitted for this role',
            StrSubstNo('operation "%1" requires the "%2" permission set (or a higher Wicket rung); the calling principal holds a lower one. Retrying will not help — an administrator must assign the role.', Operation, RequiredRole));
    end;
}
