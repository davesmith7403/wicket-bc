table 94104 "Bcmag Procedure Catalog"
{
    Caption = 'Wicket Procedure Catalog';
    DataClassification = SystemMetadata;
    LookupPageId = "Bcmag Procedure Catalog List";
    DrillDownPageId = "Bcmag Procedure Catalog List";

    fields
    {
        // The logical codeunit id is what the caller addresses; the wrapper codeunit is the
        // small auditable codeunit that actually runs (RunFromBcmag pattern). Reflection over
        // arbitrary public methods is never used — only enrolled wrappers are callable.
        field(1; "Logical Codeunit Id"; Integer) { Caption = 'Logical Codeunit Id'; NotBlank = true; }
        field(2; "Procedure Name"; Text[120]) { Caption = 'Procedure Name'; NotBlank = true; }
        field(10; "Wrapper Codeunit Id"; Integer) { Caption = 'Wrapper Codeunit Id'; NotBlank = true; }
        field(11; "Args Schema"; Blob) { Caption = 'Args Schema'; }
        field(12; "Return Shape"; Enum "Bcmag Return Shape") { Caption = 'Return Shape'; }
        field(13; "Allow Run"; Boolean) { Caption = 'Allow Run'; }
        field(20; "Description"; Text[250]) { Caption = 'Description'; }
    }

    keys
    {
        key(PK; "Logical Codeunit Id", "Procedure Name") { Clustered = true; }
    }

    procedure SetArgsSchema(SchemaJson: Text)
    var
        OutStr: OutStream;
    begin
        Clear("Args Schema");
        "Args Schema".CreateOutStream(OutStr, TextEncoding::UTF8);
        OutStr.WriteText(SchemaJson);
    end;

    procedure GetArgsSchema() Result: Text
    var
        InStr: InStream;
        Line: Text;
    begin
        CalcFields("Args Schema");
        if not "Args Schema".HasValue() then exit('');
        "Args Schema".CreateInStream(InStr, TextEncoding::UTF8);
        while not InStr.EOS() do begin
            InStr.ReadText(Line);
            Result += Line;
        end;
    end;
}
