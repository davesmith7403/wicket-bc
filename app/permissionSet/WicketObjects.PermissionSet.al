permissionset 94102 "Wicket - Objects"
{
    // BUILDING BLOCK, never assigned directly. Execute on every Wicket object a data-plane caller
    // needs to reach the endpoint and run the READ operations, plus the async/maintenance
    // plumbing. It grants NO table data (that is "Wicket - Read") and deliberately omits the
    // codeunits that define the privilege ladder, so a role is exactly the sum of the sets it
    // includes:
    //   - invoke / action wrappers ......... "Wicket - Execute"
    //   - insert / modify / delete ......... "Wicket - Edit"
    //   - log purge + admin pages .......... "Wicket - Audit" / "Wicket - Admin"
    // Execute on a codeunit is checked by the platform on first call, so a principal holding only
    // this set (through "Wicket - Read") cannot run the write or invoke handlers at all — the
    // dispatcher's Read-Only Mode is a second, tenant-wide gate on top of this per-principal one.
    // Admin/list pages are NOT here: page Execute is a UI grant, an API caller never needs it, and
    // the log/queue pages show every principal's rows (a cross-caller disclosure surface).
    Assignable = false;
    Caption = 'Wicket - Objects';
    Permissions =
        // Tables (object execute; data rights live in the Read/Audit/Admin sets)
        table "Bcmag Setup" = X,
        table "Bcmag Exposure" = X,
        table "Bcmag Field Exposure" = X,
        table "Bcmag Procedure Catalog" = X,
        table "Bcmag Operation Log" = X,
        table "Bcmag Idempotency Log" = X,
        table "Bcmag Idempotency Reservation" = X,
        table "Bcmag Request Queue" = X,
        table "Bcmag Action Catalog" = X,
        table "Bcmag Execute Gate" = X,
        table "Bcmag Write Gate" = X,
        table "Bcmag Classification Rule" = X,
        table "Bcmag Mask Profile" = X,
        table "Bcmag Access Exception" = X,
        table "Bcmag Unmask Gate" = X,
        table "Bcmag Change Entry" = X,
        table "Bcmag Field Change" = X,
        table "Bcmag Changes Gate" = X,
        // The single HTTP surface
        page "Bcmag Rpc Endpoint" = X,
        // Dispatch + cross-cutting
        codeunit "Bcmag Rpc Dispatcher" = X,
        codeunit "Bcmag Op Runner" = X,
        codeunit "Bcmag Op Runner Context" = X,
        codeunit "Bcmag Role Gate" = X,
        codeunit "Bcmag Op Authorizer" = X,
        codeunit "Bcmag Envelope" = X,
        codeunit "Bcmag Problem" = X,
        codeunit "Bcmag Logger" = X,
        codeunit "Bcmag Change Recorder" = X,
        codeunit "Bcmag Idempotency Guard" = X,
        codeunit "Bcmag Json Read" = X,
        // Projection / filtering / policy (shared by the read plane)
        codeunit "Bcmag Field Name Resolver" = X,
        codeunit "Bcmag Type Mapper" = X,
        codeunit "Bcmag Projector" = X,
        codeunit "Bcmag Caption Resolver" = X,
        codeunit "Bcmag Record Id Codec" = X,
        codeunit "Bcmag Filter Lexer" = X,
        codeunit "Bcmag Filter Parser" = X,
        codeunit "Bcmag Filter Applier" = X,
        codeunit "Bcmag Field Policy" = X,
        codeunit "Bcmag Policy Defaults" = X,
        codeunit "Bcmag Field Masker" = X,
        codeunit "Bcmag Hash Key" = X,
        // Read operations
        codeunit "Bcmag Op Discover" = X,
        codeunit "Bcmag Op Describe" = X,
        codeunit "Bcmag Api Catalog" = X,
        codeunit "Bcmag App Info" = X,
        codeunit "Bcmag Op Query" = X,
        codeunit "Bcmag Op Aggregate" = X,
        codeunit "Bcmag Op Read Blob" = X,
        codeunit "Bcmag Op Capabilities" = X,
        codeunit "Bcmag Op Skill" = X,
        codeunit "Bcmag Op Page Url" = X,
        codeunit "Bcmag Op Who Am I" = X,
        // Async delivery (a query whose result is delivered to blob storage is still a read)
        codeunit "Bcmag Async Enqueuer" = X,
        codeunit "Bcmag Async Worker" = X,
        codeunit "Bcmag Async Failure" = X,
        codeunit "Bcmag Async Reaper" = X,
        codeunit "Bcmag Async Reaper Guard" = X,
        codeunit "Bcmag Async Queue Purge" = X,
        codeunit "Bcmag Async Enqueue Run" = X,
        codeunit "Bcmag Async Cancel" = X,
        codeunit "Bcmag Azure Client" = X,
        codeunit "Bcmag Sas Signer" = X,
        codeunit "Bcmag Package Builder" = X,
        codeunit "Bcmag Op Status" = X,
        codeunit "Bcmag Op Requests" = X,
        codeunit "Bcmag Op Changes" = X,
        // Lifecycle (run in system context; listed so the set describes the whole extension)
        codeunit "Bcmag Install" = X,
        codeunit "Bcmag Upgrade" = X;
}
