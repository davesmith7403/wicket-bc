page 94113 "Bcmag Field Changes"
{
    // The changed fields of the selected change entry: old and new value as the field policy showed the
    // field when it changed, checked again against today's policy (Bcmag Op Changes.ShownAs): a field
    // that has since become masked shows its mask, one that has since become hidden only that it changed.
    PageType = ListPart;
    SourceTable = "Bcmag Field Change";
    Caption = 'Changed Fields';
    Editable = false;

    layout
    {
        area(Content)
        {
            repeater(Lines)
            {
                field(FieldName; Rec."Field Name") { ApplicationArea = All; ToolTip = 'The field that changed.'; }
                field(OldValue; OldText) { ApplicationArea = All; Caption = 'Old Value'; ToolTip = 'The value before the change.'; }
                field(NewValue; NewText) { ApplicationArea = All; Caption = 'New Value'; ToolTip = 'The value after the change.'; }
                field(ShownAs; Shown) { ApplicationArea = All; Caption = 'Shown As'; ToolTip = 'How the field is shown: the more restrictive of how the field policy showed it when it changed and how it shows it now (Clear, Masked, or Hidden).'; }
                field(Truncated; Rec.Truncated) { ApplicationArea = All; ToolTip = 'The value was longer than Max Value Length on the Wicket Setup card and was cut.'; }
            }
        }
    }

    var
        Entry: Record "Bcmag Change Entry";
        Policy: Codeunit "Bcmag Field Policy";
        OpChanges: Codeunit "Bcmag Op Changes";
        OldText, NewText: Text;
        Shown: Enum "Bcmag Read Access";
        HiddenTxt: Label 'changed (hidden by field policy)';

    trigger OnAfterGetRecord()
    begin
        if Entry."Entry No." <> Rec."Entry No." then
            if not Entry.Get(Rec."Entry No.") then
                Clear(Entry);
        OldText := Rec."Old Value";
        NewText := Rec."New Value";
        Shown := OpChanges.ShownAs(Policy, Entry."Table Id", Rec."Field No.", Rec."Stored As", OldText, NewText);
        if Shown = Shown::Hidden then
            OldText := HiddenTxt;
    end;
}
