table 94107 "Bcmag Action Catalog"
{
    // Named business actions layered over the invoke plane. Where `invoke` runs an enrolled wrapper by
    // raw codeunit id, an `action` is a stable, discoverable verb (e.g. "post-sales") with metadata that
    // capabilities.actions surfaces for every row (enabled or not): whether it mutates, whether it
    // supports a preview, and an args schema. Deny-by-default: an action is reachable only when a row
    // exists AND Allow Run is set. The wrapper is any invoke wrapper codeunit (typically shipped by a
    // Base-App companion), referenced here by id — no interface plumbing, so a new action needs no
    // Wicket core change.
    //
    // SECURITY: enrolment here is a permission-grade grant. Actions deliberately bypass the table
    // Exposure allowlist and the field policy — the catalog row IS the gate, and the wrapper codeunit
    // can read and write any table its code touches. Enabling an action (Allow Run) grants whatever
    // its wrapper does, independent of table exposure and field policy; review a wrapper like a
    // permission set before enabling it.
    Caption = 'Wicket Action Catalog';
    DataClassification = SystemMetadata;
    LookupPageId = "Bcmag Action Catalog List";
    DrillDownPageId = "Bcmag Action Catalog List";

    fields
    {
        field(1; "Action Code"; Code[50]) { Caption = 'Action Code'; NotBlank = true; }
        field(10; "Description"; Text[250]) { Caption = 'Description'; }
        field(11; "Category"; Text[50]) { Caption = 'Category'; }        // e.g. "post", "release"
        field(20; "Wrapper Codeunit Id"; Integer) { Caption = 'Wrapper Codeunit Id'; NotBlank = true; }
        // Enforced, not advisory. Is Mutating = false runs the wrapper inside the forced rollback (Bcmag
        // Action Rollback: explicit commits ignored, a nested return-value Codeunit.Run refused, every
        // write rolled back), which is also what lets such a verb — and any preview — through Read-Only
        // Mode and the key requirement. Preview Supported gates data.preview = true, which runs in the same
        // boundary but relies on the wrapper honouring args.preview (see Bcmag Action Rollback).
        field(30; "Is Mutating"; Boolean) { Caption = 'Is Mutating'; InitValue = true; }
        field(31; "Preview Supported"; Boolean) { Caption = 'Preview Supported'; }
        field(32; "Allow Run"; Boolean) { Caption = 'Allow Run'; }
        field(40; "Args Schema"; Blob) { Caption = 'Args Schema'; }
    }

    keys
    {
        key(PK; "Action Code") { Clustered = true; }
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
        if not "Args Schema".HasValue() then
            exit('');
        "Args Schema".CreateInStream(InStr, TextEncoding::UTF8);
        while not InStr.EOS() do begin
            InStr.ReadText(Line);
            Result += Line;
        end;
    end;
}
