codeunit 94329 "Bcmag Test WS Install"
{
    // Registers Bcmag Test Runner WS as the Tenant Web Service "AutoTestRunner" so it is callable at
    // .../ODataV4/AutoTestRunner_RunAllTests (see that codeunit). Test app only — never ships.
    // OnInstallAppPerDatabase runs on a FIRST install only; a dev-endpoint republish of an already
    // installed test app is an upgrade, so Bcmag Test WS Upgrade calls Register() from its trigger too.
    Subtype = Install;

    var
        ServiceNameTok: Label 'AutoTestRunner', Locked = true;

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
            if (TenantWebService."Object ID" <> Codeunit::"Bcmag Test Runner WS") or not TenantWebService.Published then begin
                TenantWebService."Object ID" := Codeunit::"Bcmag Test Runner WS";
                TenantWebService.Published := true;
                TenantWebService.Modify(true);
            end;
            exit;
        end;
        TenantWebService.Init();
        TenantWebService."Object Type" := TenantWebService."Object Type"::Codeunit;
        TenantWebService."Object ID" := Codeunit::"Bcmag Test Runner WS";
        TenantWebService."Service Name" := ServiceNameTok;
        TenantWebService.Published := true;
        TenantWebService.Insert(true);
    end;
}
