codeunit 94205 "Bcmag Act New Company"
{
    // OnInstallAppPerCompany runs only for companies that exist at install time. A company created
    // LATER would have no catalog/exposure rows for the action wrappers, so an admin could not even
    // find them to enable. Enrol from the platform Company table's insert event — the same pattern
    // the core app uses (codeunit "Bcmag Install") — rather than Base App's
    // "Company-Initialize".OnCompanyInitialize, which fires on first company USE, not creation; the
    // insert event seeds the rows immediately so they are visible to an admin. Rows enrol DISABLED (see
    // "Bcmag Act Install"), so seeding a new company opens nothing. Wrapped in a TryFunction:
    // enrolment must never throw into — and break — company creation.

    [EventSubscriber(ObjectType::Table, Database::Company, 'OnAfterInsertEvent', '', false, false)]
    local procedure EnrolOnNewCompany(var Rec: Record Company; RunTrigger: Boolean)
    begin
        // A temporary Company record (wizards and copy-company previews insert them) is not a company.
        if Rec.IsTemporary() then
            exit;
        if Rec.Name = '' then
            exit;
        if TryEnrolCompany(Rec.Name) then;
    end;

    [TryFunction]
    local procedure TryEnrolCompany(NewCompany: Text)
    var
        Install: Codeunit "Bcmag Act Install";
    begin
        Install.EnrolAllForCompany(NewCompany);
    end;
}
