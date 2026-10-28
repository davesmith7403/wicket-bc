permissionset 94107 "Wicket - Admin"
{
    // CONTROL-PLANE ADMINISTRATOR. The human (or job-queue user) who configures Wicket: the
    // exposure allowlist and field policy, the Mode / Read-Only kill-switches and limits, invoke and
    // action enrolment, the Azure credential, and audit-log retention (codeunit "Bcmag Log Purge",
    // run from a Job Queue Entry under a user holding this set). Includes the full data-plane
    // caller ("Wicket - Edit") and the viewer ("Wicket - Audit").
    //
    // Every grant here is a policy-grade grant: whoever holds this set can expose any table, enable
    // any wrapper and erase the audit trail. Give it to operators only — never to the principal an
    // agent calls with, unless that principal is meant to administer policy.
    //
    // It deliberately does NOT include "Wicket - Unmask": reading masked fields in clear is a data
    // grant, not an administrative one. An administrator can still edit the rules, profiles and
    // per-user exceptions that decide what is masked — and those changes are what the audit trail shows.
    Assignable = true;
    Caption = 'Wicket - Admin';
    IncludedPermissionSets = "Wicket - Edit", "Wicket - Audit";
    Permissions =
        tabledata "Bcmag Setup" = RIMD,
        tabledata "Bcmag Exposure" = RIMD,
        tabledata "Bcmag Field Exposure" = RIMD,
        tabledata "Bcmag Classification Rule" = RIMD,
        tabledata "Bcmag Mask Profile" = RIMD,
        tabledata "Bcmag Access Exception" = RIMD,
        tabledata "Bcmag Procedure Catalog" = RIMD,
        tabledata "Bcmag Action Catalog" = RIMD,
        tabledata "Bcmag Operation Log" = RIMD,
        tabledata "Bcmag Idempotency Log" = RIMD,
        tabledata "Bcmag Idempotency Reservation" = RIMD,
        tabledata "Bcmag Request Queue" = RIMD,
        tabledata "Bcmag Execute Gate" = RIMD,
        tabledata "Bcmag Write Gate" = RIMD,
        page "Bcmag Secret Input" = X,
        codeunit "Bcmag Log Purge" = X;
}
