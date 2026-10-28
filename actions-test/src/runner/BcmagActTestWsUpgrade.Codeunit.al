codeunit 94392 "Bcmag Act Test WS Upgrade"
{
    // Companion to Bcmag Act Test WS Install: a republish of an already installed test app runs the
    // upgrade triggers, not the install ones, so the web service is (re)registered here.
    Subtype = Upgrade;

    trigger OnUpgradePerDatabase()
    var
        TestWsInstall: Codeunit "Bcmag Act Test WS Install";
    begin
        TestWsInstall.Register();
    end;
}
