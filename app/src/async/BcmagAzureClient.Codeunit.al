codeunit 94131 "Bcmag Azure Client"
{
    // Azure Blob Storage client for async result delivery. This is the interface Layer 3 (the queue
    // worker) and Layer 4 (the stream-proxy page) code against: configuration probing, container
    // provisioning, blob upload/download/delete, and download-URL composition. Credentials never
    // live in a table or a log — they are held as SecretText in IsolatedStorage (DataScope::Company)
    // and only ever handed to the System Application ABS/authorization APIs.
    //
    // System Application dependency ONLY: everything here is namespace System.Azure.Storage
    // ("Storage Service Authorization", "ABS Blob Client", "ABS Container Client",
    // "ABS Operation Response") plus System.Utilities ("Uri"). No Base App.

    Access = Public;

    var
        CredKeyLbl: Label 'BcmagAzureCredential', Locked = true;
        ReadSasKeyLbl: Label 'BcmagAzureReadSas', Locked = true;
        UnknownAuthModeErr: Label 'Unsupported Azure auth mode.', Locked = true;

    procedure IsConfigured(): Boolean
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.GetSingleton();
        exit(
            Setup."Async Enabled" and
            (Setup."Azure Storage Account" <> '') and
            (Setup."Azure Blob Container" <> '') and
            HasCredential());
    end;

    procedure HasCredential(): Boolean
    begin
        exit(IsolatedStorage.Contains(CredKeyLbl, DataScope::Company));
    end;

    [NonDebuggable]
    procedure SetCredential(Cred: Text)
    var
        CredSecret: SecretText;
    begin
        CredSecret := Cred;
        IsolatedStorage.Set(CredKeyLbl, CredSecret, DataScope::Company);
    end;

    [NonDebuggable]
    procedure SetReadySas(SasToken: Text)
    begin
        // Second secret, used only for Download Mode = Ready SAS. Kept separate from the account
        // credential so the two can be rotated independently. Stored as PLAIN Text on purpose: a value
        // written through the SecretText overload can never be read back as Text on SaaS (the runtime
        // aborts "to prevent exposing a secret value"; SecretText.Unwrap is on-prem only), and this
        // token's whole job is to be appended in clear text to the package URL handed to callers — it
        // is a bearer capability, not a credential that stays inside the service. Both accessors are
        // [NonDebuggable] so it still never shows in a debugger.
        IsolatedStorage.Set(ReadSasKeyLbl, SasToken, DataScope::Company);
    end;

    [NonDebuggable]
    procedure ClearReadySas()
    begin
        // Rotation/decommission: drop the download token. With Download Mode = Ready SAS the enqueuer
        // then refuses new work (ValidateDownloadConfiguration) instead of handing out unsigned URLs.
        if IsolatedStorage.Contains(ReadSasKeyLbl, DataScope::Company) then
            IsolatedStorage.Delete(ReadSasKeyLbl, DataScope::Company);
    end;

    // The DOWNLOAD half of the configuration. IsConfigured() proves only that an upload can be
    // attempted; whether the resulting package can ever be fetched depends on Download Mode and on a
    // secret that mode may need. Checked by the enqueuer before a job is accepted and by the worker
    // before a job is marked Succeeded, so a request is never accepted (or reported delivered) with a
    // URL that cannot work. Returns false with a caller-facing Detail naming what is missing.
    procedure ValidateDownloadConfiguration(var Detail: Text): Boolean
    var
        Setup: Record "Bcmag Setup";
        ReadySas: Text;
    begin
        Setup.GetSingleton();
        case Setup."Download Mode" of
            Setup."Download Mode"::StreamProxy:
                begin
                    // Designed as a Wicket API page that re-authorizes the caller and streams the blob, but
                    // DEFERRED (async design note, 2026-07-04): under it BuildDownloadUrl returns a bare,
                    // unauthenticated blob URL that cannot be downloaded from a private container.
                    Detail := 'Download Mode "Stream Proxy" is not available in this build; set Download Mode to Service SAS or Ready SAS on the Wicket Setup card';
                    exit(false);
                end;
            Setup."Download Mode"::ServiceSas:
                begin
                    // The signer HMACs with the stored upload credential AS the account key. Under Ready SAS
                    // upload auth that credential is a SAS token, so every signature would be wrong.
                    if Setup."Azure Auth Mode" <> Setup."Azure Auth Mode"::SharedKey then begin
                        Detail := 'Download Mode "Service SAS" signs with the storage account key, which requires Azure Auth Mode "Shared Key"; with Ready SAS upload authentication set Download Mode to Ready SAS and store a read token';
                        exit(false);
                    end;
                    exit(true);
                end;
            Setup."Download Mode"::ReadySAS:
                begin
                    if not GetReadySas(ReadySas) then begin
                        Detail := 'Download Mode "Ready SAS" needs a usable stored read SAS token (Wicket Setup card, "Set Azure Ready SAS"); none is stored, or the stored one must be re-entered';
                        exit(false);
                    end;
                    exit(CheckReadySasToken(ReadySas, Setup."Package TTL Hours", Detail));
                end;
        end;
        Detail := 'unsupported Download Mode';
        exit(false);
    end;

    // The stored Ready SAS is handed to every caller inside their package URL, so what it grants is
    // what each caller gets. Refused: a token without read (sp lacks r) — every download would 403; a
    // token WITH list (sp has l) — a container-scoped token that lists would let any package holder
    // enumerate, and then download, every other caller's package in the container; and a token that is
    // expired or expires within the package TTL — a package delivered now would outlive its URL. A token
    // that carries no se (expiry held by a stored access policy, si=) cannot be judged here and passes.
    procedure CheckReadySasToken(Token: Text; PackageTtlHours: Integer; var Detail: Text): Boolean
    var
        UriHelper: Codeunit Uri;
        Permissions, ExpiryText: Text;
        Expiry: DateTime;
        Ms: BigInteger;
    begin
        // The token rides on every package URL handed to every caller, so it must grant read and
        // NOTHING else: list would let a package holder enumerate everyone's packages, and write,
        // create, add or delete would let them overwrite or remove them. (No sp at all means the
        // permissions come from a stored access policy, which Wicket cannot inspect.)
        Permissions := SasParam(Token, 'sp');
        if (Permissions <> '') and (Permissions <> 'r') then begin
            Detail := 'the stored Ready SAS token must grant read only (sp=r), but grants sp=' + Permissions + ' — every package holder receives this token, so list would expose other callers'' packages and write/delete would let them alter them; mint a read-only token and store it with "Set Azure Ready SAS"';
            exit(false);
        end;
        ExpiryText := SasParam(Token, 'se');
        if ExpiryText = '' then
            exit(true);
        ExpiryText := UriHelper.UnescapeDataString(ExpiryText);
        // Azure also accepts a date-only se (YYYY-MM-DD, midnight UTC).
        if StrLen(ExpiryText) = 10 then
            ExpiryText += 'T00:00:00Z';
        if not TryEvalIsoDateTime(ExpiryText, Expiry) then begin
            Detail := 'the stored Ready SAS token has an unreadable expiry (se=' + ExpiryText + '); store a valid token with "Set Azure Ready SAS"';
            exit(false);
        end;
        Ms := PackageTtlHours;
        Ms := Ms * 3600000;
        if Expiry <= CurrentDateTime() + Ms then begin
            Detail := StrSubstNo('the stored Ready SAS token expires at %1, before a package delivered now would expire (Package TTL %2 hours); store a longer-lived token with "Set Azure Ready SAS"', ExpiryText, PackageTtlHours);
            exit(false);
        end;
        exit(true);
    end;

    // Value of one query parameter of a SAS token ('a=1&b=2', optionally with a leading '?'), '' if absent.
    local procedure SasParam(Token: Text; Name: Text): Text
    var
        Part: Text;
    begin
        if Token.StartsWith('?') then
            Token := CopyStr(Token, 2);
        foreach Part in Token.Split('&') do
            if Part.StartsWith(Name + '=') then
                exit(CopyStr(Part, StrLen(Name) + 2));
        exit('');
    end;

    [TryFunction]
    local procedure TryEvalIsoDateTime(Input: Text; var Dt: DateTime)
    begin
        Evaluate(Dt, Input, 9);
    end;

    // ---- Destination ----------------------------------------------------------------------------
    // A package's storage destination (account, container, endpoint) is recorded ON THE QUEUE ROW, and
    // every blob operation below targets the row's destination — never the current Setup. Setup is read
    // only when a destination is STAMPED (at enqueue, and again when the worker starts, so a scheduled
    // job records what it actually uploads to). An administrator who later repoints Setup at another
    // container or account therefore cannot make a download URL name the wrong place, or let cleanup
    // "confirm" absence (BlobNotFound) in a container the package never lived in and strand it there.
    // The credential is the single one in IsolatedStorage: a package in an account that credential no
    // longer opens fails its delete and stays Pending — visibly overdue, never Done.

    procedure StampDestination(var Row: Record "Bcmag Request Queue")
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.GetSingleton();
        Row."Blob Account" := CopyStr(Setup."Azure Storage Account", 1, MaxStrLen(Row."Blob Account"));
        Row."Blob Container" := CopyStr(Setup."Azure Blob Container", 1, MaxStrLen(Row."Blob Container"));
        Row."Blob Endpoint" := CopyStr(Setup."Azure Blob Endpoint", 1, MaxStrLen(Row."Blob Endpoint"));
    end;

    // The row's recorded destination. Blank parts (a row stamped before "Blob Account"/"Blob Endpoint"
    // existed) fall back to Setup — the best knowledge there is for such a row. An endpoint belongs to
    // its account, so Setup's endpoint is inherited only together with Setup's account.
    procedure DestinationOf(Row: Record "Bcmag Request Queue"; var Account: Text; var Container: Text; var Endpoint: Text)
    var
        Setup: Record "Bcmag Setup";
    begin
        Account := Row."Blob Account";
        Container := Row."Blob Container";
        Endpoint := Row."Blob Endpoint";
        if (Account <> '') and (Container <> '') then
            exit;
        Setup.GetSingleton();
        if Account = '' then begin
            Account := Setup."Azure Storage Account";
            if Endpoint = '' then
                Endpoint := Setup."Azure Blob Endpoint";
        end;
        if Container = '' then
            Container := Setup."Azure Blob Container";
    end;

    // Raised immediately before each request this client sends, naming the destination it is about to
    // address. The test suite (which has no Azure) subscribes to prove that an operation goes where the
    // ROW says, not where Setup points now. Subscribers must not write to the database: the delete path
    // raises this inside a try function.
    [IntegrationEvent(false, false)]
    local procedure OnBeforeBlobRequest(Verb: Text; Account: Text; Container: Text; Endpoint: Text; BlobName: Text)
    begin
    end;

    local procedure InitBlobClient(var BlobClient: Codeunit "ABS Blob Client"; Verb: Text; Row: Record "Bcmag Request Queue")
    var
        Account, Container, Endpoint: Text;
    begin
        DestinationOf(Row, Account, Container, Endpoint);
        OnBeforeBlobRequest(Verb, Account, Container, Endpoint, Row."Blob Name");
        BlobClient.Initialize(Account, Container, BuildAuthorization());
        if Endpoint <> '' then
            BlobClient.SetBaseUrl(Endpoint);
    end;

    // Best-effort provisioning: the worker treats a false return as advisory and lets the upload decide
    // (its error is the one that matters). Skipped entirely under Ready SAS upload auth: such a token is
    // normally container-scoped and cannot create containers, so the call would always fail, and the
    // container necessarily exists already for the token to have been minted against it.
    procedure EnsureContainer(Row: Record "Bcmag Request Queue"; var ErrorText: Text): Boolean
    var
        Setup: Record "Bcmag Setup";
        ContainerClient: Codeunit "ABS Container Client";
        Response: Codeunit "ABS Operation Response";
        Account, Container, Endpoint: Text;
    begin
        Setup.GetSingleton();
        if Setup."Azure Auth Mode" = Setup."Azure Auth Mode"::ReadySAS then
            exit(true);
        DestinationOf(Row, Account, Container, Endpoint);
        OnBeforeBlobRequest('createContainer', Account, Container, Endpoint, '');
        ContainerClient.Initialize(Account, BuildAuthorization());
        if Endpoint <> '' then
            ContainerClient.SetBaseUrl(Endpoint);
        Response := ContainerClient.CreateContainer(Container);
        if Response.IsSuccessful() then
            exit(true);
        ErrorText := Response.GetError();
        // A 409 ContainerAlreadyExists is the expected steady state — provisioning is idempotent.
        if HasServiceErrorCode(Response, ErrorText, 'ContainerAlreadyExists') then begin
            ErrorText := '';
            exit(true);
        end;
        exit(false);
    end;

    procedure UploadStream(Row: Record "Bcmag Request Queue"; var SourceInStr: InStream; ContentType: Text; var ErrorText: Text): Boolean
    var
        BlobClient: Codeunit "ABS Blob Client";
        Response: Codeunit "ABS Operation Response";
    begin
        InitBlobClient(BlobClient, 'put', Row);
        Response := BlobClient.PutBlobBlockBlobStream(Row."Blob Name", SourceInStr, ContentType);
        if Response.IsSuccessful() then
            exit(true);
        ErrorText := Response.GetError();
        exit(false);
    end;

    procedure DownloadStream(Row: Record "Bcmag Request Queue"; var TargetInStr: InStream; var ErrorText: Text): Boolean
    var
        BlobClient: Codeunit "ABS Blob Client";
        Response: Codeunit "ABS Operation Response";
    begin
        // Feeds the stream-proxy page: it re-authorizes the caller, then streams the blob back so
        // no Azure credential ever leaves the service.
        InitBlobClient(BlobClient, 'get', Row);
        Response := BlobClient.GetBlobAsStream(Row."Blob Name", TargetInStr);
        if Response.IsSuccessful() then
            exit(true);
        ErrorText := Response.GetError();
        exit(false);
    end;

    // Remove a package blob at the row's recorded destination. TRUE means the blob is confirmed ABSENT
    // there afterwards — either this call deleted it or the service reported BlobNotFound (already gone:
    // a repeated reaper run, a manual purge). FALSE means it may still exist (auth failure, network,
    // throttling): the caller must keep the cleanup pending and retry. The old DeleteBlobIfExists
    // returned false for BOTH "absent" and "failed", which made its result unusable as a retry signal —
    // so callers ignored it.
    procedure RemoveBlob(Row: Record "Bcmag Request Queue"; var ErrorText: Text): Boolean
    var
        Deleted, Absent: Boolean;
    begin
        ClearLastError();
        if not TryRemoveBlob(Row, Deleted, Absent, ErrorText) then begin
            // The ABS helper raised (e.g. the request itself could not be sent) — treat as not deleted.
            ErrorText := GetLastErrorText();
            exit(false);
        end;
        exit(Deleted or Absent);
    end;

    [TryFunction]
    local procedure TryRemoveBlob(Row: Record "Bcmag Request Queue"; var Deleted: Boolean; var Absent: Boolean; var ErrorText: Text)
    var
        BlobClient: Codeunit "ABS Blob Client";
        Response: Codeunit "ABS Operation Response";
    begin
        // No database write in here: on-prem servers forbid writes inside try functions.
        InitBlobClient(BlobClient, 'delete', Row);
        Response := BlobClient.DeleteBlob(Row."Blob Name");
        if Response.IsSuccessful() then begin
            Deleted := true;
            exit;
        end;
        ErrorText := Response.GetError();
        // BlobNotFound is the one "failure" that is a success here. Only a 404 of THAT code counts: a
        // ContainerNotFound / ResourceNotFound from a wrong account or endpoint must keep cleanup pending.
        Absent := HasServiceErrorCode(Response, ErrorText, 'BlobNotFound');
    end;

    // Azure Blob Storage names every failure in the x-ms-error-code response header; that header is the
    // authoritative signal (ABS Operation Response exposes no HTTP status code, only the headers and an
    // error text). The error text is checked too, for a response whose headers could not be read.
    local procedure HasServiceErrorCode(var Response: Codeunit "ABS Operation Response"; ErrorText: Text; ErrorCode: Text): Boolean
    var
        HeaderValue: Text;
    begin
        if TryGetErrorCodeHeader(Response, HeaderValue) then
            if HeaderValue <> '' then
                exit(HeaderValue = ErrorCode);
        exit(StrPos(ErrorText, ErrorCode) > 0);
    end;

    // No database access: reading a header of a response that never arrived may raise.
    [TryFunction]
    local procedure TryGetErrorCodeHeader(var Response: Codeunit "ABS Operation Response"; var HeaderValue: Text)
    begin
        HeaderValue := Response.GetHeaderValueFromResponseHeaders('x-ms-error-code');
    end;

    procedure ComposeBlobUrl(Row: Record "Bcmag Request Queue"): Text
    var
        Account, Container, Endpoint: Text;
    begin
        DestinationOf(Row, Account, Container, Endpoint);
        exit(StrSubstNo('%1/%2/%3', BlobEndpoint(Account, Endpoint), Container, EscapeBlobPath(Row."Blob Name")));
    end;

    // The caller-facing download URL, composed at RESPONSE time (accepted response, status) and never
    // stored: the row keeps only the tokenless blob URL. Service SAS mints a fresh token valid for SAS TTL
    // Minutes but never past the package's Expires At, so a status read hours after completion still
    // yields a working URL for as long as the package lives. Ready SAS appends the stored token, whose own
    // expiry applies. A signing fault yields the bare URL (it fails at Azure) rather than an error here.
    procedure BuildDownloadUrl(Row: Record "Bcmag Request Queue"): Text
    var
        Setup: Record "Bcmag Setup";
        SasSigner: Codeunit "Bcmag Sas Signer";
        Account, Container, Endpoint, ReadySas, Token: Text;
        Expiry: DateTime;
    begin
        Setup.GetSingleton();
        case Setup."Download Mode" of
            Setup."Download Mode"::StreamProxy:
                // Layer 4's stream-proxy API page wraps this bare blob URL and re-authorizes the
                // caller before streaming; no credential is embedded in the returned URL.
                exit(ComposeBlobUrl(Row));
            Setup."Download Mode"::ServiceSas:
                begin
                    DestinationOf(Row, Account, Container, Endpoint);
                    Expiry := CurrentDateTime() + SasSigner.SasTtl(Setup."SAS TTL Minutes");
                    if (Row."Expires At" <> 0DT) and (Row."Expires At" < Expiry) then
                        Expiry := Row."Expires At";
                    if TryMintReadSas(Account, Container, Row."Blob Name", Expiry, Token) then
                        exit(ComposeBlobUrl(Row) + '?' + Token);
                    exit(ComposeBlobUrl(Row));
                end;
            Setup."Download Mode"::ReadySAS:
                begin
                    if GetReadySas(ReadySas) then
                        exit(ComposeBlobUrl(Row) + '?' + ReadySas);
                    exit(ComposeBlobUrl(Row));
                end;
        end;
        exit(ComposeBlobUrl(Row));
    end;

    // No database access inside (MintReadSasUntil reads only IsolatedStorage).
    [TryFunction]
    local procedure TryMintReadSas(Account: Text; Container: Text; BlobName: Text; Expiry: DateTime; var Token: Text)
    var
        SasSigner: Codeunit "Bcmag Sas Signer";
    begin
        Token := SasSigner.MintReadSasUntil(Account, Container, BlobName, Expiry);
    end;

    local procedure BuildAuthorization(): Interface "Storage Service Authorization"
    var
        Setup: Record "Bcmag Setup";
        AuthFactory: Codeunit "Storage Service Authorization";
        CredSecret: SecretText;
    begin
        Setup.GetSingleton();
        GetCredential(CredSecret);
        case Setup."Azure Auth Mode" of
            Setup."Azure Auth Mode"::SharedKey:
                exit(AuthFactory.CreateSharedKey(CredSecret));
            Setup."Azure Auth Mode"::ReadySAS:
                exit(AuthFactory.UseReadySAS(CredSecret));
        end;
        Error(UnknownAuthModeErr);
    end;

    [NonDebuggable]
    local procedure GetCredential(var CredSecret: SecretText): Boolean
    begin
        exit(IsolatedStorage.Get(CredKeyLbl, DataScope::Company, CredSecret));
    end;

    [NonDebuggable]
    local procedure GetReadySas(var ReadySas: Text): Boolean
    begin
        // Fetched as Text because it has to be appended to a URL (see SetReadySas). A token stored by
        // an earlier build through the SecretText overload cannot be read back on SaaS — that read is
        // a runtime abort, caught here and reported as "no usable token" so the administrator
        // re-enters it through Set Azure Ready SAS instead of the request failing with a 500.
        ReadySas := '';
        if not IsolatedStorage.Contains(ReadSasKeyLbl, DataScope::Company) then
            exit(false);
        ClearLastError();
        if not TryGetReadySas(ReadySas) then
            exit(false);
        exit(ReadySas <> '');
    end;

    [NonDebuggable]
    [TryFunction]
    local procedure TryGetReadySas(var ReadySas: Text)
    begin
        IsolatedStorage.Get(ReadSasKeyLbl, DataScope::Company, ReadySas);
    end;

    local procedure BlobEndpoint(Account: Text; Endpoint: Text): Text
    begin
        if Endpoint <> '' then
            exit(Endpoint);
        exit(StrSubstNo('https://%1.blob.core.windows.net', Account));
    end;

    local procedure EscapeBlobPath(BlobName: Text): Text
    var
        UriHelper: Codeunit Uri;
        Segment: Text;
        Builder: TextBuilder;
    begin
        // Percent-escape each path segment but keep the '/' separators intact so virtual-folder
        // blob names ("2026/07/04/pkg.ndjson") survive round-tripping.
        foreach Segment in BlobName.Split('/') do begin
            if Builder.Length() > 0 then
                Builder.Append('/');
            Builder.Append(UriHelper.EscapeDataString(Segment));
        end;
        exit(Builder.ToText());
    end;
}
