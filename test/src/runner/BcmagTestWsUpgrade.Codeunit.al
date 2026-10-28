codeunit 94330 "Bcmag Test WS Upgrade"
{
    // Companion to Bcmag Test WS Install: a republish of the test app to a sandbox where it is already
    // installed runs the upgrade triggers, not the install ones, so the web service is (re)registered here.
    Subtype = Upgrade;

    trigger OnUpgradePerDatabase()
    var
        TestWsInstall: Codeunit "Bcmag Test WS Install";
    begin
        TestWsInstall.Register();
    end;
}
