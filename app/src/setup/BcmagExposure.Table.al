table 94101 "Bcmag Exposure"
{
    Caption = 'Wicket Exposure';
    DataClassification = SystemMetadata;
    LookupPageId = "Bcmag Exposure List";
    DrillDownPageId = "Bcmag Exposure List";

    fields
    {
        field(1;  "Object Type";   Option)  { Caption = 'Object Type';
            OptionMembers = Table,Codeunit;
            OptionCaption = 'Table,Codeunit'; }
        field(2;  "Object Id";     Integer) { Caption = 'Object Id'; NotBlank = true; }
        field(10; "Allow Read";    Boolean) { Caption = 'Allow Read';   InitValue = true; }
        field(11; "Allow Insert";  Boolean) { Caption = 'Allow Insert'; }
        field(12; "Allow Modify";  Boolean) { Caption = 'Allow Modify'; }
        field(13; "Allow Delete";  Boolean) { Caption = 'Allow Delete'; }
        field(14; "Allow Invoke";  Boolean) { Caption = 'Allow Invoke'; }
        field(20; "Description";   Text[100]) { Caption = 'Description'; }
    }

    keys { key(PK; "Object Type", "Object Id") { Clustered = true; } }

    procedure IsAllowed(ObjectType: Option Table,Codeunit; ObjectId: Integer; Op: Text): Boolean
    var
        Setup: Record "Bcmag Setup";
        Row: Record "Bcmag Exposure";
    begin
        Setup.GetSingleton();

        // Hard denylist: the extension's own control/audit tables (Setup, Exposure, Operation Log,
        // Idempotency Log, Procedure Catalog) — and anything else in its reserved table range — can
        // NEVER be WRITTEN through the generic data plane, in ANY Mode. Without this, an Open-mode
        // caller could modify the allowlist or the Mode kill-switch, insert a Procedure Catalog row to
        // enrol an arbitrary invoke wrapper, or delete/alter the audit log — defeating deny-by-default
        // and tampering with the audit trail. These tables are written only via their admin pages.
        // Reads are intentionally NOT blocked here (that is a separate, lower-severity concern), so a
        // Wicket table can still serve as a read fixture. invoke (codeunit plane) is exempt: enrolled
        // wrapper codeunits legitimately live in this object range and stay gated by Allow Run.
        if (ObjectType = ObjectType::Table) and (ObjectId >= 94100) and (ObjectId <= 94199) and (Op in ['insert', 'modify', 'delete']) then
            exit(false);

        // The audit/queue tables hold OTHER principals' data: an Idempotency Log row stores the full
        // response body of every idempotent write, a Request Queue row stores each caller's query and
        // a package URL that may embed a SAS token, the Operation Log names every caller, and an
        // Idempotency Reservation row pairs a caller's security id with their idempotency keys, body
        // hashes and in-flight state. Reading them through the generic data plane (query/readBlob/
        // describe/pageUrl) would let any RPC principal — in Open mode, ANY caller — read across
        // principals and defeat the caller-scoping that status/requests/replay/reserve enforce. Denied
        // in every Mode; the admin pages remain the only way to inspect them. Setup, Exposure and the
        // catalogs stay readable: they hold policy, not data, so they can still serve as read fixtures.
        // The field-masking policy splits the same way:
        //   - Access Exception rows are per-principal grants (which user may see which field in clear or
        //     is tightened, with a free-text Reason and the User Name FlowField) — other principals'
        //     data, so denied like the audit tables.
        //   - Field Exposure rows name every field an administrator hid, masked or opened, plus a free
        //     note. The field plane deliberately makes a Hidden field indistinguishable from a
        //     nonexistent one (describe, select, filter), and reading these rows would undo that, so
        //     they are denied too. (The table-level Exposure stays readable: a table's exposure is
        //     already observable as not-exposed, so its rows reveal nothing new.)
        //   - Classification Rules and Mask Profiles stay readable: capabilities publishes both to
        //     every caller, so denying them would hide nothing.
        //   - The change history (Change Entry, Field Change) names every principal's changes and holds
        //     copies of their values; its gate table is listed with it. The page and the caller-scoped
        //     changes operation are the ways to read it.
        // The role-gate sentinel tables (Write, Execute, Unmask) are empty by design and need no entry.
        if (ObjectType = ObjectType::Table) and (Op = 'read') and
           (ObjectId in [Database::"Bcmag Operation Log", Database::"Bcmag Idempotency Log",
                         Database::"Bcmag Idempotency Reservation", Database::"Bcmag Request Queue",
                         Database::"Bcmag Access Exception", Database::"Bcmag Field Exposure",
                         Database::"Bcmag Change Entry", Database::"Bcmag Field Change", Database::"Bcmag Changes Gate"])
        then
            exit(false);

        // invoke is ALWAYS deny-by-default: Open mode only bypasses the per-row check for
        // invoke when the admin has explicitly enabled it. Procedure-level Allow Run in the
        // Procedure Catalog remains a second, independent gate.
        if Setup.Mode = Setup.Mode::Open then begin
            if Op <> 'invoke' then
                exit(true);
            if Setup."Allow Invoke In Open Mode" then
                exit(true);
        end;
        if not Row.Get(ObjectType, ObjectId) then
            exit(false);
        case Op of
            'read':
                exit(Row."Allow Read");
            'insert':
                exit(Row."Allow Insert");
            'modify':
                exit(Row."Allow Modify");
            'delete':
                exit(Row."Allow Delete");
            'invoke':
                exit(Row."Allow Invoke");
        end;
        exit(false);
    end;
}
