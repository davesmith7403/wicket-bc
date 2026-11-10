table 94301 "Bcmag Test Unshared Record"
{
    // A second table of the test app that the test rig does NOT grant: only a principal holding a data
    // set (or SUPER) can read it, so it tells a Wicket rung without data rights from one with them.
    Caption = 'Wicket Test Unshared Record';
    DataClassification = SystemMetadata;

    fields
    {
        field(1; "Code"; Code[20]) { Caption = 'Code'; }
    }

    keys { key(PK; "Code") { Clustered = true; } }
}
