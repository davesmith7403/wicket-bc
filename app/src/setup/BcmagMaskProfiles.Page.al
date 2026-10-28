page 94110 "Bcmag Mask Profiles"
{
    PageType = List;
    SourceTable = "Bcmag Mask Profile";
    Caption = 'Wicket Mask Profiles';
    UsageCategory = Administration;
    ApplicationArea = All;
    InsertAllowed = true;
    ModifyAllowed = true;
    DeleteAllowed = true;

    layout
    {
        area(content)
        {
            repeater(Group)
            {
                field(ProfileCode;    Rec."Code")            { ApplicationArea = All; ToolTip = 'The code that classification rules, field exposure rows and access exceptions refer to.'; }
                field(Description;    Rec.Description)       { ApplicationArea = All; ToolTip = 'What the profile is for.'; }
                field(Kind;           Rec.Kind)              { ApplicationArea = All; ToolTip = 'How the value is masked: keep the first and/or last characters, keep an email''s first letter and domain, emit fixed text, emit null, or emit a keyed hash.'; }
                field(KeepFirst;      Rec."Keep First")      { ApplicationArea = All; ToolTip = 'Characters revealed at the start (Keep First, Keep First and Last).'; }
                field(KeepLast;       Rec."Keep Last")       { ApplicationArea = All; ToolTip = 'Characters revealed at the end (Keep Last, Keep First and Last).'; }
                field(MinHidden;      Rec."Min Hidden")      { ApplicationArea = All; ToolTip = 'A value too short to hide at least this many characters after keeping its ends is masked completely.'; }
                field(MaskChar;       Rec."Mask Char")       { ApplicationArea = All; ToolTip = 'The character that replaces hidden characters.'; }
                field(PreserveLength; Rec."Preserve Length") { ApplicationArea = All; ToolTip = 'Emit one mask character per hidden character. Off emits a fixed run, because the length of a value is itself information.'; }
                field(FixedText;      Rec."Fixed Text")      { ApplicationArea = All; ToolTip = 'The text emitted by a Fixed Text profile.'; }
            }
        }
    }
}
