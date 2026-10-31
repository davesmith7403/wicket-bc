permissionset 94103 "Wicket - Read"
{
    // DATA-PLANE READER. Assign to a principal (S2S app user or delegated user) that may only
    // read through the RPC: discover, describe, query (+ aggregate, async deliver), readBlob,
    // capabilities, skill, pageUrl, whoAmI, and its own status / requests / cancel. It has no
    // Execute on the insert/modify/delete/invoke/action handlers (see "Wicket - Objects"), so a
    // mutating call fails at the platform permission check regardless of Read-Only Mode,
    // exposure rows, or whatever business-data sets the principal also holds.
    //
    // What it can write, and why — all of it is Wicket's own system/audit state, never policy:
    //   Setup ............ I  GetSingleton lazily materialises the singleton (install seeds it;
    //                         this is the safety net for a company created outside the hook)
    //   Operation Log .... I  the per-request audit row (Logger.Write, best-effort)
    //   Idempotency Log .. I  the replay snapshot for an idempotent request
    //   Change Entry ..... ri the change history of its own writes, actions and procedures, and the
    //   Field Change ..... ri caller's own entries through the changes operation. Indirect only: the
    //                         tables hold every principal's values, so a Read user never opens them
    //                         in the client (Wicket - Audit Changes reads them directly).
    //   Request Queue .... IM enqueue its own async request; the worker (running as the caller)
    //                         advances the row; cancel sets the cooperative flag. Never D.
    // Reads on Exposure / Field Exposure / the catalogs are what the deny-by-default gates consult;
    // the classification rules, mask profiles and access exceptions are what the field policy consults
    // to reach a caller's read verdict (Hidden / Masked / Clear).
    // Tenant Media R is what readBlob needs to stream a Media field.
    //
    // This grants NOTHING on business data. Pair it with "Wicket Data - Read" (read everything),
    // a standard D365 read set, or a customer-built set naming the tables in scope.
    Assignable = true;
    Caption = 'Wicket - Read';
    IncludedPermissionSets = "Wicket - Objects";
    Permissions =
        tabledata "Bcmag Setup" = RI,
        // discover/describe report which installed app owns a table; capabilities fingerprints them.
        tabledata "NAV App Installed App" = R,
        tabledata "Bcmag Exposure" = R,
        tabledata "Bcmag Field Exposure" = R,
        tabledata "Bcmag Classification Rule" = R,
        tabledata "Bcmag Mask Profile" = R,
        tabledata "Bcmag Access Exception" = R,
        tabledata "Bcmag Procedure Catalog" = R,
        tabledata "Bcmag Action Catalog" = R,
        tabledata "Bcmag Operation Log" = RI,
        tabledata "Bcmag Idempotency Log" = RI,
        tabledata "Bcmag Idempotency Reservation" = RIM,   // take (I), settle/take over (M); never delete
        tabledata "Bcmag Request Queue" = RIM,
        // The change history: written (I) by the recorder for the caller's own writes, actions and
        // procedures; read (R) by the changes operation, which returns a caller's own entries only.
        tabledata "Bcmag Change Entry" = ri,
        tabledata "Bcmag Field Change" = ri,
        tabledata "Tenant Media" = R;
}
