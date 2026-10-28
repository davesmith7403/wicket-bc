table 94109 "Bcmag Write Gate"
{
    // Role sentinel, never holds a row. Only "Wicket - Edit" (and Admin) grants RIMD on this table. The
    // dispatcher asks Record.WritePermission on it before routing insert/modify/delete, so the generic
    // write plane is closed to every lower rung — including "Wicket Data - Exec", whose codeunit
    // wildcard reaches the write handlers themselves — with a typed 403 role-forbidden, not a 500.
    // See "Bcmag Execute Gate" for the invoke/action counterpart.
    Caption = 'Wicket Write Gate';
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
