page 94108 "Bcmag Action Catalog List"
{
    // Admin view of named actions. Allow Run is the deny-by-default gate; the wrapper codeunit is
    // supplied by an action provider (typically a Base-App companion) and enrolled on install.
    //
    // SECURITY: enabling an action is a permission-grade grant. Actions deliberately bypass the table
    // Exposure allowlist and the field policy — this catalog row IS the gate, and the wrapper codeunit
    // can read and write any table its code touches. Review a wrapper like a permission set before
    // enabling it.
    Caption = 'Wicket Action Catalog';
    PageType = List;
    ApplicationArea = All;
    UsageCategory = Lists;
    SourceTable = "Bcmag Action Catalog";

    layout
    {
        area(content)
        {
            group(SecurityNotice)
            {
                ShowCaption = false;
                InstructionalText = 'Enabling an action grants whatever its wrapper codeunit does, independent of which tables are exposed and of the field policy. Review a wrapper like a permission set before enabling it.';
            }
            repeater(ActionRows)
            {
                field(ActionCode; Rec."Action Code") { ApplicationArea = All; }
                field(Category; Rec.Category) { ApplicationArea = All; }
                field(AllowRun; Rec."Allow Run")
                {
                    ApplicationArea = All;
                    ToolTip = 'Specifies whether the action can be run. Enabling it grants whatever the wrapper codeunit does, independent of table exposure and field policy — review the wrapper like a permission set first.';
                }
                field(IsMutating; Rec."Is Mutating") { ApplicationArea = All; }
                field(PreviewSupported; Rec."Preview Supported") { ApplicationArea = All; }
                field(WrapperCodeunitId; Rec."Wrapper Codeunit Id")
                {
                    ApplicationArea = All;
                    ToolTip = 'Specifies the codeunit that implements the action. It runs under the calling principal''s permissions, but is not constrained by the exposure list or the field policy — it can touch any table the caller''s permission sets allow.';
                }
                field(Description; Rec.Description) { ApplicationArea = All; }
            }
        }
    }
}
