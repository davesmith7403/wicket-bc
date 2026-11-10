table 94118 "Bcmag Read Gate"
{
    // Role sentinel, never holds a row. "Wicket - Read" (and every rung above it) grants RIMD on this
    // table. The dispatcher asks Record.WritePermission on it before anything else, so a principal that
    // can reach the endpoint without holding a data-plane rung — the viewer sets "Wicket - Audit" and
    // "Wicket - Audit Changes" carry the object rung for their pages — gets a typed 403 role-forbidden.
    // Without it such a principal ran the read operations its other rights allowed and left no row in
    // the Operation Log, which only the Read rung may insert into.
    // See "Bcmag Execute Gate" and "Bcmag Write Gate" for the rungs above.
    Caption = 'Wicket Read Gate';
    DataClassification = SystemMetadata;
    Access = Public;

    fields
    {
        field(1; "Primary Key"; Code[10]) { Caption = 'Primary Key'; DataClassification = SystemMetadata; }
    }

    keys
    {
        key(PK; "Primary Key") { Clustered = true; }
    }
}
