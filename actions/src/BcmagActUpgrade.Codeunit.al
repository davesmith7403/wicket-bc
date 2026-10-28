codeunit 94206 "Bcmag Act Upgrade"
{
    // Re-runs enrolment on upgrade so actions added in a later version get their catalog and exposure
    // rows in every existing company, and refreshes the companion-owned fields of existing catalog rows
    // (Description and Wrapper Codeunit Id, plus Category, Preview Supported and Args Schema on actions,
    // and Is Mutating only from false to true), so documentation, routing and metadata fixes reach tenants that enrolled
    // earlier. The admin's Allow Run / Allow Invoke choices are never touched, and any NEW rows enrol
    // disabled, so an upgrade is safe to re-run and opens nothing.
    Subtype = Upgrade;

    trigger OnUpgradePerCompany()
    var
        Install: Codeunit "Bcmag Act Install";
    begin
        Install.RefreshAll();
    end;
}
