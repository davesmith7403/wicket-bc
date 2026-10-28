page 94107 "Bcmag Secret Input"
{
    // Modal, source-less prompt for a single masked secret (Azure account key / SAS token). The value
    // lives only in a page variable and is read back through GetValue by the caller, which hands it
    // straight to IsolatedStorage — it is never persisted to a table or shown again.
    PageType = StandardDialog;
    Caption = 'Enter Secret';
    InstructionalText = 'Paste the secret. It is stored encrypted and cannot be displayed again.';
    Extensible = false;
    ApplicationArea = All;

    layout
    {
        area(content)
        {
            group(SecretGroup)
            {
                ShowCaption = false;
                field(SecretValue; SecretValue)
                {
                    ApplicationArea = All;
                    Caption = 'Value';
                    ExtendedDatatype = Masked;
                    ShowMandatory = true;
                    ToolTip = 'Specifies the secret value to store (masked).';
                }
            }
        }
    }

    var
        SecretValue: Text;

    [NonDebuggable]
    procedure GetValue(): Text
    begin
        exit(SecretValue);
    end;
}
