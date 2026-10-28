permissionset 94104 "Wicket - Execute"
{
    // DATA-PLANE READ + EXECUTE. Everything "Wicket - Read" can do, plus the invoke and action
    // operations: run an ENROLLED wrapper codeunit (Exposure Allow Invoke + Procedure Catalog /
    // Action Catalog Allow Run remain the runtime gates). Still no Execute on the insert / modify /
    // delete handlers, so the generic write plane stays closed to this role.
    //
    // "Execute" is only as read-only as the wrappers it can reach: a wrapper runs under the
    // caller's permissions and may write whatever those permissions (or the wrapper's own
    // Permissions property) allow. This set grants no wrapper — each provider ships its own
    // (e.g. "Wicket Act" in the Actions companion) and the operator enables rows per company.
    Assignable = true;
    Caption = 'Wicket - Execute';
    IncludedPermissionSets = "Wicket - Read";
    Permissions =
        // Rung sentinel (empty table): RIMD here is what lets the dispatcher route invoke/action for this
        // principal. Nothing below this rung grants it; a tabledata wildcard yields Read only.
        tabledata "Bcmag Execute Gate" = RIMD,
        codeunit "Bcmag Op Invoke" = X,
        codeunit "Bcmag Op Action" = X,
        codeunit "Bcmag Action Rollback" = X,   // the forced-rollback boundary for previews and non-mutating verbs
        codeunit "Bcmag Invoke Context" = X,
        codeunit "Bcmag Wrap Ping" = X;    // sample wrapper (ping) — harmless, enrolled by the operator
}
