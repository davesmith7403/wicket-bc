table 94112 "Bcmag Mask Profile"
{
    // How a Masked value is rendered. Referenced by classification rules, per-field rows and per-user
    // exceptions; a blank or unknown code renders as the built-in partial mask (keep the last 2, at
    // least 4 hidden), so a dangling reference can never fall open to the clear value.
    // Min Hidden is the leak guard: a value too short to keep its ends AND hide at least this many
    // characters is masked completely. Preserve Length off (the default) always emits a fixed run of
    // mask characters, because the length of a value is itself information.
    Caption = 'Wicket Mask Profile';
    DataClassification = SystemMetadata;
    LookupPageId = "Bcmag Mask Profiles";
    DrillDownPageId = "Bcmag Mask Profiles";

    fields
    {
        field(1;  "Code";            Code[20])               { Caption = 'Code'; NotBlank = true; }
        field(2;  Description;       Text[100])              { Caption = 'Description'; }
        field(10; Kind;              Enum "Bcmag Mask Kind") { Caption = 'Kind'; }
        field(11; "Keep First";      Integer)                { Caption = 'Keep First'; MinValue = 0; }
        field(12; "Keep Last";       Integer)                { Caption = 'Keep Last'; MinValue = 0; }
        field(13; "Min Hidden";      Integer)                { Caption = 'Min Hidden'; MinValue = 1; InitValue = 4; }
        field(14; "Mask Char";       Text[1])                { Caption = 'Mask Char'; InitValue = '*'; }
        field(15; "Preserve Length"; Boolean)                { Caption = 'Preserve Length'; }
        field(16; "Fixed Text";      Text[30])               { Caption = 'Fixed Text'; InitValue = '[redacted]'; }
    }

    keys { key(PK; "Code") { Clustered = true; } }
}
