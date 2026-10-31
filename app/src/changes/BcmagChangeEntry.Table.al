table 94115 "Bcmag Change Entry"
{
    // One record the agent created, changed or deleted through Wicket, or one action or enrolled
    // procedure it ran — the header of the change history; its fields are in "Bcmag Field Change".
    // Written by "Bcmag Change Recorder" in the same transaction as the change (for actions and
    // procedures, after their run). Holds other principals' rows: never readable through the data
    // plane (Bcmag Exposure.IsAllowed); the Wicket Changes page and the changes operation read it.
    Caption = 'Wicket Change Entry';
    DataClassification = SystemMetadata;
    DrillDownPageId = "Bcmag Changes";
    LookupPageId = "Bcmag Changes";

    fields
    {
        field(1; "Entry No."; BigInteger) { Caption = 'Entry No.'; AutoIncrement = true; }
        field(2; "Request Id"; Text[64]) { Caption = 'Request Id'; }
        field(3; "Created At"; DateTime) { Caption = 'Created At'; }
        field(4; Kind; Enum "Bcmag Change Kind") { Caption = 'What'; }
        field(5; "Table Id"; Integer) { Caption = 'Table Id'; }
        field(6; "Table Name"; Text[30]) { Caption = 'Table'; }
        field(7; "Record Key"; Text[250]) { Caption = 'Record'; DataClassification = CustomerContent; }
        field(8; "Record SystemId"; Guid) { Caption = 'Record SystemId'; }
        field(9; "User Security Id"; Guid) { Caption = 'User Security Id'; DataClassification = EndUserPseudonymousIdentifiers; }
        field(10; "User Id"; Code[50]) { Caption = 'User'; DataClassification = EndUserIdentifiableInformation; }
        field(11; Connection; Text[80]) { Caption = 'Connection'; }
        field(12; "Field Count"; Integer) { Caption = 'Fields'; }
        field(13; Name; Text[100]) { Caption = 'Action or Procedure'; }
        field(14; Outcome; Text[50]) { Caption = 'Outcome'; }
        field(15; Result; Text[250]) { Caption = 'Result'; DataClassification = CustomerContent; }
    }

    keys
    {
        key(PK; "Entry No.") { Clustered = true; }
        key(Created; "Created At") { }
        key(ByUser; "User Security Id", "Created At") { }
        key(ByTable; "Table Id", "Created At") { }
    }
}
