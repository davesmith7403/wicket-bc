table 94300 "Bcmag Test Record"
{
    // A table of the test app's own for the restricted-identity tests: writing it needs no Base
    // Application permission set and runs no other extension's subscribers, so a refusal can only come
    // from Wicket's own objects and tables.
    Caption = 'Wicket Test Record';
    DataClassification = SystemMetadata;

    fields
    {
        field(1; "Code"; Code[20]) { Caption = 'Code'; }
        field(2; Name; Text[100]) { Caption = 'Name'; }
        field(3; Note; Blob) { Caption = 'Note'; }
    }

    keys { key(PK; "Code") { Clustered = true; } }
}
