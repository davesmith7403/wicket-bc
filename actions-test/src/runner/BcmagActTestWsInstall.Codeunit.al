codeunit 94391 "Bcmag Act Test WS Install"
{
    // Registers Bcmag Act Test Runner WS as the Tenant Web Service "AutoTestRunnerActions"
    // (.../ODataV4/AutoTestRunnerActions_RunAllTests). OnInstallAppPerDatabase runs on a FIRST install
    // only; a dev-endpoint republish is an upgrade, so Bcmag Act Test WS Upgrade calls Register() too.
    Subtype = Install;

    var
        ServiceNameTok: Label 'AutoTestRunnerActions', Locked = true;

    trigger OnInstallAppPerDatabase()
    begin
        Register();
    end;

    procedure Register()
    var
        TenantWebService: Record "Tenant Web Service";
    begin
        // An entry can survive the app it pointed at (an uninstall leaves Tenant Web Service rows behind,
        // and the 2026-10-10 renumber moved the runner): repoint it instead of trusting it.
        if TenantWebService.Get(TenantWebService."Object Type"::Codeunit, ServiceNameTok) then begin
            if (TenantWebService."Object ID" <> Codeunit::"Bcmag Act Test Runner WS") or not TenantWebService.Published then begin
                TenantWebService."Object ID" := Codeunit::"Bcmag Act Test Runner WS";
                TenantWebService.Published := true;
                TenantWebService.Modify(true);
            end;
            exit;
        end;
        TenantWebService.Init();
        TenantWebService."Object Type" := TenantWebService."Object Type"::Codeunit;
        TenantWebService."Object ID" := Codeunit::"Bcmag Act Test Runner WS";
        TenantWebService."Service Name" := ServiceNameTok;
        TenantWebService.Published := true;
        TenantWebService.Insert(true);
    end;
}
