table 94108 "Bcmag Execute Gate"
{
    // Role sentinel, never holds a committed row (Bcmag Action Rollback inserts one per session to open a
    // write transaction and always rolls it back). "Wicket - Execute" (and every rung above it) grants RIMD on this
    // table; nothing below it does, and a tabledata wildcard (the Data sets) yields Read only. The
    // dispatcher asks Record.WritePermission on it before routing invoke/action, so a caller on the read
    // rung gets a typed 403 role-forbidden instead of the platform's Execute denial surfacing as a 500.
    // Permission sets are additive and cannot carve an exception out of `codeunit * = X`; this table is
    // how the rung stays a real boundary even for callers who hold such a wildcard elsewhere.
    Caption = 'Wicket Execute Gate';
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
