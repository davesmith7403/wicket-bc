page 94106 "Bcmag Request Queue List"
{
    // Admin view of async delivery requests. Read-only: status is driven by the workers, not edited
    // by hand. Cancellation from the UI sets the cooperative flag / cancels the scheduled task.
    Caption = 'Wicket Request Queue';
    PageType = List;
    ApplicationArea = All;
    UsageCategory = Lists;
    SourceTable = "Bcmag Request Queue";
    Editable = false;

    layout
    {
        area(content)
        {
            repeater(Requests)
            {
                field("Entry No."; Rec."Entry No.") { ApplicationArea = All; }
                field(RequestId; Rec.PublicId()) { ApplicationArea = All; Caption = 'Request Id'; }
                field(Status; Rec.Status) { ApplicationArea = All; }
                field(Operation; Rec.Operation) { ApplicationArea = All; }
                field(Origin; Rec.Origin) { ApplicationArea = All; }
                field("Package Format"; Rec."Package Format") { ApplicationArea = All; }
                field("Created At"; Rec."Created At") { ApplicationArea = All; }
                field("Scheduled For"; Rec."Scheduled For") { ApplicationArea = All; }
                field("Started At"; Rec."Started At") { ApplicationArea = All; }
                field("Completed At"; Rec."Completed At") { ApplicationArea = All; }
                field("Progress Rows"; Rec."Progress Rows") { ApplicationArea = All; }
                field("Result Row Count"; Rec."Result Row Count") { ApplicationArea = All; }
                field("Result Bytes"; Rec."Result Bytes") { ApplicationArea = All; }
                field("Cancel Requested"; Rec."Cancel Requested") { ApplicationArea = All; }
                field("Expires At"; Rec."Expires At") { ApplicationArea = All; }
                field("Blob Account"; Rec."Blob Account") { ApplicationArea = All; }
                field("Blob Container"; Rec."Blob Container") { ApplicationArea = All; }
                field("Blob Cleanup"; Rec."Blob Cleanup") { ApplicationArea = All; }
                field("Cleanup Attempts"; Rec."Cleanup Attempts") { ApplicationArea = All; }
                field("Problem Type"; Rec."Problem Type") { ApplicationArea = All; }
                // Never the stored value verbatim: a row from an earlier build may carry a live SAS token,
                // and this page is visible to the Audit role across every caller.
                field(PackageUrl; Rec.DisplayPackageUrl()) { ApplicationArea = All; Caption = 'Package Url'; }
            }
        }
    }

    actions
    {
        area(processing)
        {
            action(CancelRequest)
            {
                ApplicationArea = All;
                Caption = 'Cancel';
                ToolTip = 'Cancel the selected request: a scheduled request is cancelled outright, a running or queued one is asked to stop at its next checkpoint.';
                Image = Cancel;

                trigger OnAction()
                var
                    AsyncCancel: Codeunit "Bcmag Async Cancel";
                begin
                    AsyncCancel.CancelRow(Rec);
                    CurrPage.Update(false);
                end;
            }
        }
    }

    trigger OnOpenPage()
    begin
        Rec.SetCurrentKey("Entry No.");
        Rec.Ascending(false);
    end;
}
