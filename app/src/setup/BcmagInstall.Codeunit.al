codeunit 94120 "Bcmag Install"
{
    // Materialises the singleton Setup row on install so the extension is in a known state.
    // Exposure stays empty (deny-by-default): the operator enrols tables/codeunits and, for invoke,
    // procedures. Upgrades from an earlier version are handled by codeunit "Bcmag Upgrade", which
    // backfills Setup fields added after 1.0. See docs/setup-entra.md and the Wicket Exposure page.
    Subtype = Install;

    trigger OnInstallAppPerCompany()
    var
        UpgradeTag: Codeunit "Upgrade Tag";
        Upgrade: Codeunit "Bcmag Upgrade";
    begin
        EnsureSetup();
        EnsureFieldPolicyDefaults();
        EnsureHashKey();
        EnsureReaper();
        // A fresh install has no legacy queue rows: the one-time destination stamp is already "done".
        if not UpgradeTag.HasUpgradeTag(Upgrade.QueueDestinationTag()) then
            UpgradeTag.SetUpgradeTag(Upgrade.QueueDestinationTag());
        // A fresh singleton is born with Log Request Details on: the one-time upgrade switch is done.
        if not UpgradeTag.HasUpgradeTag(Upgrade.RequestDetailsTag()) then
            UpgradeTag.SetUpgradeTag(Upgrade.RequestDetailsTag());
    end;

    local procedure EnsureSetup()
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.GetSingleton();
    end;

    // Seed the classification rules and mask profiles so an administrator sees the shipped posture as
    // editable rows. Insert-only: a reinstall never overwrites a rule or profile already there. A company
    // created later gets no rows from here, which is harmless — a missing rule resolves to the same
    // built-in default the seed would have written.
    local procedure EnsureFieldPolicyDefaults()
    var
        PolicyDefaults: Codeunit "Bcmag Policy Defaults";
    begin
        PolicyDefaults.SeedFieldPolicyDefaults();
    end;

    // The tenant HMAC key (strong ETag, Hash masks) is created here so no request path has to write it.
    local procedure EnsureHashKey()
    var
        HashKey: Codeunit "Bcmag Hash Key";
    begin
        HashKey.EnsureKey();
    end;

    // Arm the async-maintenance reaper (stale-worker recovery + package expiry) for this company. It is
    // self-re-arming; Ensure is idempotent (it only schedules a task when none is live) and defensive
    // (a context that cannot create tasks is a no-op), so install never breaks over it.
    local procedure EnsureReaper()
    var
        Reaper: Codeunit "Bcmag Async Reaper";
    begin
        Reaper.Ensure();
    end;

    // OnInstallAppPerCompany runs only for companies that exist at install time. A company created
    // LATER would have no Setup singleton — and because the API endpoint (page 94100) is keyed on that
    // singleton, EVERY operation in that company would 404 at the OData layer before any AL of ours
    // runs. The CodeCop-recommended hook for this (Codeunit "Company-Initialize"."OnCompanyInitialize")
    // lives in the Base Application, which this extension deliberately does not depend on, so seed the
    // singleton from the platform Company table's insert event instead. Wrapped in a TryFunction:
    // seeding must never throw into — and break — company creation.
    [EventSubscriber(ObjectType::Table, Database::Company, 'OnAfterInsertEvent', '', false, false)]
    local procedure EnsureSetupOnNewCompany(var Rec: Record Company; RunTrigger: Boolean)
    begin
        // A temporary Company record (wizards and copy-company previews insert them) is not a company.
        if Rec.IsTemporary() then
            exit;
        if Rec.Name = '' then
            exit;
        if TrySeedCompany(Rec.Name) then;
    end;

    [TryFunction]
    local procedure TrySeedCompany(CompanyName: Text)
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.ChangeCompany(CompanyName);
        Setup.GetSingleton();
    end;
}
