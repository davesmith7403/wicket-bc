codeunit 94128 "Bcmag Upgrade"
{
    // Backfills Setup fields added after 1.0 on tenants upgrading from an earlier version. A field's
    // InitValue applies only when Init() creates a NEW row, so the pre-existing singleton keeps the
    // SQL defaults (0 / '') for Max Filter Length (17), Max Select Fields (18) and Default Languages
    // (19). Left at 0 those limits reject every filtered or projected query with a misleading 413 and
    // capabilities advertises "0". The backfill is idempotent (it only touches values still at the
    // upgrade-default), so it is safe to re-run and needs no explicit data-version gate. GetSingleton
    // additionally heals these values in memory on every read as a runtime safety net.
    Subtype = Upgrade;

    trigger OnUpgradePerCompany()
    var
        Setup: Record "Bcmag Setup";
        Reaper: Codeunit "Bcmag Async Reaper";
        PolicyDefaults: Codeunit "Bcmag Policy Defaults";
        HashKey: Codeunit "Bcmag Hash Key";
    begin
        // Arm the async-maintenance reaper on upgrade for tenants that pre-date it. Ensure is idempotent
        // (schedules only when no task is live) and defensive, so the upgrade never fails over it.
        Reaper.Ensure();

        StampQueueDestinations();

        // Classification rules and mask profiles (field masking) arrive in an upgrade with no rows;
        // insert the shipped defaults for whatever is missing. Insert-only, so an administrator's rule
        // or profile is never overwritten by a later upgrade.
        PolicyDefaults.SeedFieldPolicyDefaults();

        // Tenant HMAC key: created here so no request path has to write it (idempotent, only if absent).
        HashKey.EnsureKey();

        if not Setup.Get('') then
            exit; // no singleton yet — the install codeunit materialises it on (re)install
        if BackfillSetup(Setup) then
            Setup.Modify();
        EnableRequestDetailsOnce(Setup);
        EnableChangeHistoryOnce(Setup);
    end;

    // The change history fields arrive on an existing singleton as Off / 0 / 0 / false. The owner's
    // decision is on by default, upgrades included — so set the defaults exactly once per company; an
    // administrator's later choice is never overridden.
    procedure EnableChangeHistoryOnce(var Setup: Record "Bcmag Setup")
    var
        UpgradeTag: Codeunit "Upgrade Tag";
    begin
        if UpgradeTag.HasUpgradeTag(ChangeHistoryTag()) then
            exit;
        ApplyChangeHistoryDefaults(Setup);
        Setup.Modify();
        UpgradeTag.SetUpgradeTag(ChangeHistoryTag());
    end;

    procedure ApplyChangeHistoryDefaults(var Setup: Record "Bcmag Setup")
    begin
        Setup."Record Changes" := Setup."Record Changes"::OldAndNewValues;
        Setup."Change Retention Days" := 90;
        Setup."Max Value Length" := 250;
        Setup."Agent Can Read Changes" := true;
    end;

    procedure ChangeHistoryTag(): Code[250]
    begin
        exit('WICKET-CHANGE-HISTORY-20261029');
    end;

    // "Log Request Details" arrives in an upgrade as false on an existing singleton (InitValue applies
    // to a fresh Insert only). The intended default is on, upgrades included — so switch it
    // on exactly once per company; an administrator who turns it off afterwards is never overridden.
    local procedure EnableRequestDetailsOnce(var Setup: Record "Bcmag Setup")
    var
        UpgradeTag: Codeunit "Upgrade Tag";
    begin
        if UpgradeTag.HasUpgradeTag(RequestDetailsTag()) then
            exit;
        Setup."Log Request Details" := true;
        Setup.Modify();
        UpgradeTag.SetUpgradeTag(RequestDetailsTag());
    end;

    procedure RequestDetailsTag(): Code[250]
    begin
        exit('WICKET-LOG-REQUEST-DETAILS-20261009');
    end;

    // Queue rows written before "Blob Account"/"Blob Endpoint" existed (and the odd row without a
    // container) have their destination resolved from Setup at every blob operation — so an
    // administrator repointing Setup later would aim that row's download URL and cleanup at the wrong
    // place (cleanup could "confirm" absence in a container the package never lived in). Freeze the
    // destination now, while Setup still describes where those packages were written. Only rows whose
    // blob may still exist matter: not yet finished (Queued/Scheduled/Running), Succeeded (the package
    // lives until expiry), or any row with cleanup still Pending. Blank parts only, with the same rule
    // as the runtime fallback (Bcmag Azure Client.DestinationOf): an endpoint belongs to its account, so
    // Setup's endpoint is copied only together with Setup's account. Runs once per company (upgrade tag):
    // a later run would stamp whatever Setup says THEN, which is exactly the drift this prevents.
    local procedure StampQueueDestinations()
    var
        Setup: Record "Bcmag Setup";
        Row: Record "Bcmag Request Queue";
        UpgradeTag: Codeunit "Upgrade Tag";
        Changed: Boolean;
    begin
        if UpgradeTag.HasUpgradeTag(QueueDestinationTag()) then
            exit;
        if Setup.Get('') then
            if Row.FindSet(true) then
                repeat
                    if (Row.Status in [Row.Status::Queued, Row.Status::Scheduled, Row.Status::Running, Row.Status::Succeeded]) or
                       (Row."Blob Cleanup" = Row."Blob Cleanup"::Pending)
                    then begin
                        Changed := false;
                        if Row."Blob Account" = '' then begin
                            Row."Blob Account" := CopyStr(Setup."Azure Storage Account", 1, MaxStrLen(Row."Blob Account"));
                            if Row."Blob Endpoint" = '' then
                                Row."Blob Endpoint" := CopyStr(Setup."Azure Blob Endpoint", 1, MaxStrLen(Row."Blob Endpoint"));
                            Changed := true;
                        end;
                        if Row."Blob Container" = '' then begin
                            Row."Blob Container" := CopyStr(Setup."Azure Blob Container", 1, MaxStrLen(Row."Blob Container"));
                            Changed := true;
                        end;
                        if Changed then
                            Row.Modify();
                    end;
                until Row.Next() = 0;
        UpgradeTag.SetUpgradeTag(QueueDestinationTag());
    end;

    procedure QueueDestinationTag(): Code[250]
    begin
        exit('BCMAG-QUEUE-DESTINATION-20260923');
    end;

    // A company created after this build never has legacy queue rows: register the tag so the platform
    // marks it done for new companies (and the install codeunit sets it for companies present at install).
    [EventSubscriber(ObjectType::Codeunit, Codeunit::"Upgrade Tag", 'OnGetPerCompanyUpgradeTags', '', false, false)]
    local procedure RegisterPerCompanyTags(var PerCompanyUpgradeTags: List of [Code[250]])
    begin
        PerCompanyUpgradeTags.Add(QueueDestinationTag());
        PerCompanyUpgradeTags.Add(RequestDetailsTag());
        PerCompanyUpgradeTags.Add(ChangeHistoryTag());
    end;

    local procedure BackfillSetup(var Setup: Record "Bcmag Setup") Changed: Boolean
    begin
        if Setup."Max Filter Length" = 0 then begin
            Setup."Max Filter Length" := 2048;
            Changed := true;
        end;
        if Setup."Max Select Fields" = 0 then begin
            Setup."Max Select Fields" := 256;
            Changed := true;
        end;
        if Setup."Default Languages" = '' then begin
            Setup."Default Languages" := 'en-US';
            Changed := true;
        end;
        // Async config limits (fields 46-49) added after 1.1: a pre-existing singleton holds 0, which
        // would make async unusable (Max Active Requests = 0 rejects every request, TTL = 0 expires a
        // row at birth). Persist the InitValue defaults so the Setup Card shows real values. GetSingleton
        // heals the same fields in memory as a safety net; this write makes them durable and visible.
        if Setup."Package TTL Hours" = 0 then begin
            Setup."Package TTL Hours" := 24;
            Changed := true;
        end;
        if Setup."SAS TTL Minutes" = 0 then begin
            Setup."SAS TTL Minutes" := 60;
            Changed := true;
        end;
        if Setup."Max Schedule Ahead Days" = 0 then begin
            Setup."Max Schedule Ahead Days" := 30;
            Changed := true;
        end;
        if Setup."Max Active Requests" = 0 then begin
            Setup."Max Active Requests" := 20;
            Changed := true;
        end;
        // Write-plane policy (fields 200-201) ships SAFE for fresh installs — key required for action/
        // invoke, trigger bypass refused — but an upgrade must not break callers that relied on the old
        // behaviour: keep posting without a key working (Require Key = false, already the SQL default of
        // the pre-existing row) and keep init:false / validate:false honoured (Allow Trigger Bypass =
        // true). The marker is false only on a singleton that pre-dates these fields, so this runs once:
        // an administrator's later choice is never overwritten by a subsequent upgrade.
        if not Setup."Write Policy Defaults Set" then begin
            Setup."Require Key For Actions" := false;
            Setup."Allow Trigger Bypass" := true;
            Setup."Write Policy Defaults Set" := true;
            Changed := true;
        end;
    end;
}
