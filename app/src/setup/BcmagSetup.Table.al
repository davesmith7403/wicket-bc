table 94100 "Bcmag Setup"
{
    Caption = 'Wicket Setup';
    DataClassification = SystemMetadata;

    fields
    {
        field(1;  "Primary Key";              Code[10])  { Caption = 'Primary Key'; DataClassification = SystemMetadata; }
        field(10; "Mode";                     Enum "Bcmag Setup Mode") { Caption = 'Mode'; InitValue = Allowlisted; }
        field(11; "Default Top";              Integer)   { Caption = 'Default Top'; InitValue = 100; MinValue = 1; MaxValue = 1000; }
        field(12; "Max Top";                  Integer)   { Caption = 'Max Top'; InitValue = 1000; MinValue = 1; MaxValue = 10000; }
        field(13; "Per-Call Scan Budget";     Integer)   { Caption = 'Per-Call Scan Budget'; InitValue = 100000; MinValue = 1000; }
        field(14; "Require ETag On Writes";   Boolean)   { Caption = 'Require ETag On Writes'; }
        field(15; "Decimal String Threshold"; BigInteger){ Caption = 'Decimal String Threshold'; InitValue = 9007199254740992L; }
        field(16; "Operation Log Retention Days"; Integer){ Caption = 'Operation Log Retention Days'; InitValue = 30; }
        field(17; "Max Filter Length";       Integer)   { Caption = 'Max Filter Length'; InitValue = 2048; MinValue = 64; }
        field(18; "Max Select Fields";        Integer)   { Caption = 'Max Select Fields'; InitValue = 256; MinValue = 1; }
        field(19; "Default Languages";        Text[100]) { Caption = 'Default Languages'; InitValue = 'en-US'; }
        field(20; "Allow Invoke In Open Mode"; Boolean)  { Caption = 'Allow Invoke In Open Mode'; }
        // Field-level policy (Bcmag Field Policy). NOTE: on upgraded installs the pre-existing
        // singleton keeps option value 0 = AllFields — intentional (no silent behavior change on
        // upgrade); fresh installs start fail-closed at ByClassification. The per-classification posture
        // lives in "Bcmag Classification Rule" (Hidden / Masked / Clear + mask profile), not here.
        field(21; "Field Policy Mode";        Enum "Bcmag Field Policy Mode") { Caption = 'Field Policy Mode'; InitValue = ByClassification; }
        field(29; "Describe Restricted Fields"; Boolean) { Caption = 'Describe Restricted Fields'; }
        // Master kill-switch: when set, the endpoint refuses insert/modify/delete/invoke outright,
        // ahead of Mode, the exposure allowlist, and the app principal's BC permissions. It cannot
        // be relaxed per table — a read-only endpoint stays read-only no matter what any exposure
        // row or permission set would otherwise permit. Reads (discover/describe/query/readBlob/
        // capabilities) are unaffected. Default off, so upgrades keep their current behavior.
        field(30; "Read-Only Mode";           Boolean)   { Caption = 'Read-Only Mode'; }
        // Opt-in stronger optimistic-concurrency token: folds a hash of each row's field values into
        // the @etag, so a change that lands in the same millisecond as the caller's read (which the
        // SystemModifiedAt-only token cannot detect) still shifts the ETag. Costs a field read+hash per
        // projected row — off by default. See BcmagProjector.EtagOf.
        field(31; "Strong ETag";              Boolean)   { Caption = 'Strong ETag'; }
        // Public HTTPS URL of the hosted usage skill (markdown). The `skill` operation fetches it and
        // serves progressive disclosure (toc/section/full), so any client gets the protocol education
        // without repo access and the docs ship independently of the extension. Blank = skill disabled.
        field(32; "Skill Doc Url";            Text[250])
        {
            Caption = 'Skill Doc Url';

            trigger OnValidate()
            begin
                // Only https:// — a plain-http or internal URL turns the skill fetch into an SSRF
                // surface reachable by any endpoint caller. Bcmag Op Skill re-checks this at fetch
                // time for rows written before this validation existed.
                if ("Skill Doc Url" <> '') and not LowerCase("Skill Doc Url").StartsWith('https://') then
                    FieldError("Skill Doc Url", 'must start with https://');
            end;
        }
        // Whether describe kind "api" reports an API page as routable, i.e. whether a client (the MCP
        // server) may read it through the tenant's own API instead of the dynamic plane. Such a read
        // never passes this endpoint, so Wicket's Operation Log does not record it; the client's
        // pre-check still applies the exposure allowlist and field policy by asking describe first.
        // Off on every install (fresh and upgraded): routing is an opt-in posture.
        field(33; "API Routing";              Enum "Bcmag Api Routing") { Caption = 'API Routing'; }
        // Whether the Operation Log records each request's shape (select, filter, orderBy, top, window,
        // aggregate, a write's field names) in "Request Details". On for fresh installs and switched on
        // once by the 2026-10 upgrade: an administrator who lets an agent into the ERP expects to see
        // what it asked. A filter can carry searched-for values, so a stricter tenant turns it off.
        field(35; "Log Request Details";      Boolean)   { Caption = 'Log Request Details'; InitValue = true; }
        // Whether the "Wicket - Unmask" permission set lifts Masked fields to Clear for its holders. The tier
        // is checked as WritePermission on the "Bcmag Unmask Gate" sentinel, and SUPER holds every table
        // permission — so without this switch every SUPER user (and the test suite, which runs as SUPER)
        // would read every masked field in clear. On for fresh rows; an upgraded singleton holds false
        // (the SQL default), which leaves the tier off — the restrictive side — until an admin turns it on.
        field(34; "Unmask Tier Enabled";      Boolean)   { Caption = 'Unmask Tier Enabled'; InitValue = true; }
        // Async delivery to Azure Blob Storage. Off by default: a request carrying a "deliver" block
        // is rejected with a typed problem when this is off, never silently run inline. The storage
        // credential (account key or ready SAS) is NOT a field here — it lives in IsolatedStorage
        // (DataScope::Company) as SecretText, set via the setup card action.
        field(40; "Async Enabled";            Boolean)   { Caption = 'Async Enabled'; }
        field(41; "Azure Storage Account";    Text[100]) { Caption = 'Azure Storage Account'; }
        field(42; "Azure Blob Container";     Text[63])  { Caption = 'Azure Blob Container'; }
        // Shared Key = the account key signs each request; Ready SAS = a pre-provisioned SAS token.
        field(43; "Azure Auth Mode";          Option)    { Caption = 'Azure Auth Mode'; OptionMembers = SharedKey,ReadySAS; OptionCaption = 'Shared Key,Ready SAS'; }
        // How the returned package URL grants download access. ServiceSas (default): a hand-signed
        // per-blob read SAS (direct Azure URL; the signer is sandbox-unverified — see Bcmag Sas Signer).
        // ReadySas: append a pre-provisioned read SAS stored as SecretText. StreamProxy (option 0) was
        // designed as a Wicket API page that re-authorizes the caller and streams the blob, but that page
        // was DEFERRED and does not exist in this build: the enqueuer refuses deliver requests while it
        // is selected, because the bare blob URL it would return cannot be downloaded from a private
        // container. The option order is kept so existing rows keep their stored value.
        field(44; "Download Mode";            Option)    { Caption = 'Download Mode'; OptionMembers = StreamProxy,ServiceSas,ReadySAS; OptionCaption = 'Stream Proxy,Service SAS,Ready SAS'; InitValue = ServiceSas; }
        field(45; "Default Package Format";   Enum "Bcmag Package Format") { Caption = 'Default Package Format'; }
        field(46; "Package TTL Hours";        Integer)   { Caption = 'Package TTL Hours'; InitValue = 24; MinValue = 1; }
        field(47; "SAS TTL Minutes";          Integer)   { Caption = 'SAS TTL Minutes'; InitValue = 60; MinValue = 1; }
        field(48; "Max Schedule Ahead Days";  Integer)   { Caption = 'Max Schedule Ahead Days'; InitValue = 30; MinValue = 1; }
        field(49; "Max Active Requests";      Integer)   { Caption = 'Max Active Requests'; InitValue = 20; MinValue = 1; }
        // Optional override of the blob endpoint host (sovereign/gov clouds). Blank = the public
        // "https://<account>.blob.core.windows.net" default is composed from Azure Storage Account.
        field(50; "Azure Blob Endpoint";      Text[250]) { Caption = 'Azure Blob Endpoint'; }
        // ---- write-plane policy (200-209) ------------------------------------------------------------
        // Fresh installs (and any newly created Setup row) start SAFE; a tenant upgrading from a build
        // without these fields keeps its previous behaviour. The InitValues give the fresh-row defaults;
        // an upgraded pre-existing singleton holds the SQL defaults (false) instead, and Bcmag Upgrade
        // uses "Write Policy Defaults Set" (false only on such a row) to persist the compatible values
        // exactly once — never again after an administrator has chosen.
        //
        // action/invoke without an idempotency key → 400 idempotency-key-required. A wrapper may post
        // and COMMIT; without a key a lost response cannot be retried safely. Upgrade: false.
        field(200; "Require Key For Actions";  Boolean)   { Caption = 'Require Key For Actions'; InitValue = true; }
        // insert with init:false / modify with validate:false skip the table's OnInsert trigger or the
        // fields' OnValidate — the business rules a table enforces. Off → 403 trigger-bypass-disabled.
        // Upgrade: true (callers that relied on it keep working until an administrator turns it off).
        field(201; "Allow Trigger Bypass";     Boolean)   { Caption = 'Allow Trigger Bypass'; }
        // Marker: true on every row created by this or a later build; false only on a singleton that
        // pre-dates fields 200-201, which is how the upgrade tells "upgraded" from "fresh".
        field(202; "Write Policy Defaults Set"; Boolean)  { Caption = 'Write Policy Defaults Set'; InitValue = true; }
    }

    keys { key(PK; "Primary Key") { Clustered = true; } }

    procedure GetSingleton()
    begin
        if not Get('') then begin
            Init();
            "Primary Key" := '';
            Insert();
        end;
        HealDefaults();
    end;

    // The Setup Card's presets: one step from install to a working posture. Each sets only the gates
    // it names. The field policy and masking stay as they are except in Developer Sandbox, because
    // opening the tables is a separate decision from opening the columns. Both read-only presets also
    // clear Allow Invoke In Open Mode, so turning Read-Only Mode off later does not silently open
    // invoke. BC-side the caller still needs the sets PresetPermissionSets names: a preset moves the
    // Wicket gates, never a principal's permissions.
    procedure ApplyPreset(Preset: Enum "Bcmag Setup Preset")
    var
        EnvironmentInformation: Codeunit "Environment Information";
    begin
        GetSingleton();
        case Preset of
            Preset::SimpleReadOnly:
                begin
                    Mode := Mode::Open;
                    "Read-Only Mode" := true;
                    "Allow Invoke In Open Mode" := false;
                end;
            Preset::ReadOnlySelectedTables:
                begin
                    Mode := Mode::Allowlisted;
                    "Read-Only Mode" := true;
                    "Allow Invoke In Open Mode" := false;
                end;
            // Generic insert/modify/delete stay refused for callers below "Wicket - Edit" (the role gate),
            // and invoke stays deny-by-default; enrolled actions are gated by their own catalog.
            Preset::ReadAndActions:
                begin
                    Mode := Mode::Open;
                    "Read-Only Mode" := false;
                    "Allow Invoke In Open Mode" := false;
                end;
            Preset::DeveloperSandbox:
                begin
                    if EnvironmentInformation.IsProduction() then
                        Error(DeveloperSandboxOnProductionErr);
                    Mode := Mode::Open;
                    "Read-Only Mode" := false;
                    "Allow Invoke In Open Mode" := true;
                    "Field Policy Mode" := "Field Policy Mode"::AllFields;
                end;
            else
                Error(NotAPresetErr, Preset);
        end;
        Modify(true);
    end;

    // The preset the current gate settings match, or Custom. Read-Only Mode refuses invoke ahead of
    // Mode, so the invoke switch does not distinguish the read-only presets.
    procedure CurrentPreset(): Enum "Bcmag Setup Preset"
    begin
        if "Read-Only Mode" then begin
            if Mode = Mode::Open then
                exit("Bcmag Setup Preset"::SimpleReadOnly);
            exit("Bcmag Setup Preset"::ReadOnlySelectedTables);
        end;
        if Mode <> Mode::Open then
            exit("Bcmag Setup Preset"::Custom);
        if not "Allow Invoke In Open Mode" then
            exit("Bcmag Setup Preset"::ReadAndActions);
        if "Field Policy Mode" = "Field Policy Mode"::AllFields then
            exit("Bcmag Setup Preset"::DeveloperSandbox);
        exit("Bcmag Setup Preset"::Custom);
    end;

    procedure PresetSummary(Preset: Enum "Bcmag Setup Preset"): Text
    begin
        case Preset of
            Preset::SimpleReadOnly:
                exit(SimpleReadOnlySummaryTxt);
            Preset::ReadOnlySelectedTables:
                exit(ReadOnlySelectedSummaryTxt);
            Preset::ReadAndActions:
                exit(ReadAndActionsSummaryTxt);
            Preset::DeveloperSandbox:
                exit(DeveloperSandboxSummaryTxt);
        end;
        exit(CustomSummaryTxt);
    end;

    procedure PresetPermissionSets(Preset: Enum "Bcmag Setup Preset"): Text
    begin
        case Preset of
            Preset::SimpleReadOnly:
                exit('Wicket Data - Read');
            Preset::ReadOnlySelectedTables:
                exit(ReadOnlySelectedSetsTxt);
            Preset::ReadAndActions:
                exit('Wicket Data - Read, Wicket - Execute, Wicket Act');
            Preset::DeveloperSandbox:
                exit('Wicket - Admin');
        end;
        exit('');
    end;

    var
        DeveloperSandboxOnProductionErr: Label 'The Developer Sandbox preset opens every table and codeunit and shows every field, so it can only be applied in a sandbox environment.';
        NotAPresetErr: Label '%1 is not a preset that can be applied.', Comment = '%1 = preset caption';
        SimpleReadOnlySummaryTxt: Label 'Every table becomes readable without allowlist rows, and every write, invoke and action is refused. The field policy and masking stay as they are.';
        ReadOnlySelectedSummaryTxt: Label 'Only the tables you allow on the Exposure list are readable, and every write, invoke and action is refused. The field policy and masking stay as they are.';
        ReadAndActionsSummaryTxt: Label 'Every table becomes readable, enrolled business actions can run, and invoke stays off. Direct insert, modify and delete stay refused unless the caller holds Wicket - Edit. The field policy and masking stay as they are.';
        DeveloperSandboxSummaryTxt: Label 'Every table is readable and writable for callers with the matching permission sets, invoke is allowed on every codeunit, and the field policy shows every field. Sandbox environments only.';
        CustomSummaryTxt: Label 'The settings do not match a preset.';
        ReadOnlySelectedSetsTxt: Label 'Wicket - Read, plus a permission set with Read on the tables you allow';

    // Fields added after 1.0 (Max Filter Length 17, Max Select Fields 18, Default Languages 19) get
    // their InitValue only on a fresh Insert — never on a row that already existed before the upgrade,
    // where they default to 0 / ''. A zero limit would reject every non-empty filter and every select
    // with a misleading 413, and capabilities would advertise "0". Heal those values IN MEMORY on
    // every read so callers always see sane limits, with no write on the read path. The upgrade
    // codeunit (Bcmag Upgrade) persists the same backfill so the Setup Card shows the real values.
    local procedure HealDefaults()
    begin
        if "Max Filter Length" = 0 then
            "Max Filter Length" := 2048;
        if "Max Select Fields" = 0 then
            "Max Select Fields" := 256;
        if "Default Languages" = '' then
            "Default Languages" := 'en-US';
        HealAsyncDefaults();
    end;

    // The async config fields (44-49) are added after the async release, so a pre-existing singleton
    // holds SQL 0/first-option for them. A zero limit is not benign here: Max Active Requests = 0 makes
    // the enqueuer 429 EVERY request ("limit 0"), Package TTL Hours = 0 expires a row at birth, and Max
    // Schedule Ahead Days = 0 rejects every scheduleAt — async would be silently dead on every upgraded
    // tenant. Heal them in memory (like the 1.1 limits); Bcmag Upgrade persists the same values. These
    // only gate async, which stays off until Async Enabled is set, so healing them is inert until then.
    // Default Package Format legitimately defaults to its first option (Ndjson), and Download Mode is a
    // deliberate admin choice — a pre-existing StreamProxy value is refused by the enqueuer with a typed
    // problem rather than silently rewritten — so neither is healed.
    local procedure HealAsyncDefaults()
    begin
        if "Package TTL Hours" = 0 then
            "Package TTL Hours" := 24;
        if "SAS TTL Minutes" = 0 then
            "SAS TTL Minutes" := 60;
        if "Max Schedule Ahead Days" = 0 then
            "Max Schedule Ahead Days" := 30;
        if "Max Active Requests" = 0 then
            "Max Active Requests" := 20;
    end;
}
