codeunit 94132 "Bcmag Sas Signer"
{
    // Hand-rolled Azure "service SAS" minting, used ONLY when Download Mode = Service SAS. The System
    // Application ABS module exposes no in-app per-blob read-SAS API, so the string-to-sign is built
    // and HMAC-SHA256 signed here with the account key. Isolated in its own codeunit so a defect in
    // the (hard-to-verify) signing cannot affect the Ready SAS download path.
    //
    // !!! SANDBOX-UNVERIFIED !!!
    // The exact canonical string-to-sign below (field order, newline placement, signedVersion,
    // signedProtocol) is written to the Azure REST "Service SAS" spec but has NOT been
    // validated against a live Azure account in this environment. It MUST be verified end-to-end
    // against real Azure Blob Storage before Service SAS is relied on in production. Until then,
    // prefer Download Mode = Ready SAS (a pre-provisioned read SAS the admin mints in Azure and
    // stores through the Setup card; nothing here has to sign anything). Service SAS is nevertheless the
    // fresh-install InitValue because it only needs the account key already required for upload;
    // Ready SAS needs the admin to provision a token first. Stream Proxy is NOT an alternative:
    // it was designed but never built, and the enqueuer refuses it with a typed failure.

    Access = Public;

    var
        CredKeyLbl: Label 'BcmagAzureCredential', Locked = true;
        SignedVersionTok: Label '2022-11-02', Locked = true;

    // Account and Container are the package's RECORDED destination (see Bcmag Azure Client.DestinationOf),
    // not Setup's current values: a token signed for the wrong container is useless to the caller.
    // Validity: from 15 minutes ago (clock-skew allowance) to now + SAS TTL Minutes.
    procedure MintReadSas(Account: Text; Container: Text; BlobName: Text): Text
    var
        Setup: Record "Bcmag Setup";
    begin
        Setup.GetSingleton();
        exit(MintReadSasUntil(Account, Container, BlobName, CurrentDateTime() + SasTtl(Setup."SAS TTL Minutes")));
    end;

    // As MintReadSas, with the expiry chosen by the caller (the Azure client caps it at the package's
    // Expires At). No database access, so it may run inside a try function.
    procedure MintReadSasUntil(Account: Text; Container: Text; BlobName: Text; ExpiryUtc: DateTime): Text
    var
        St, Se, CanonicalizedResource, StringToSign, Signature : Text;
    begin
        St := FormatSasTime(CurrentDateTime() - ClockSkewAllowance());
        Se := FormatSasTime(ExpiryUtc);

        // Canonicalized resource for a blob service SAS: /blob/<account>/<container>/<blob>
        CanonicalizedResource := StrSubstNo('/blob/%1/%2/%3', Account, Container, BlobName);

        // Service-SAS string-to-sign for signedVersion 2020-12-06 and later (2022-11-02 here). Order and
        // trailing empty fields per the Azure REST reference. Empty lines are the unset optional fields
        // (signedIdentifier, signedIP, signedSnapshotTime, signedEncryptionScope, and the five response
        // override headers rscc/rscd/rsce/rscl/rsct). signedProtocol is "https" and is sent as spr=https:
        // the token must never be honoured over plain http.
        StringToSign :=
            'r' + Lf() +                       // signedPermissions
            St + Lf() +                        // signedStart
            Se + Lf() +                        // signedExpiry
            CanonicalizedResource + Lf() +     // canonicalizedResource
            '' + Lf() +                        // signedIdentifier
            '' + Lf() +                        // signedIP
            'https' + Lf() +                   // signedProtocol
            SignedVersionTok + Lf() +          // signedVersion
            'b' + Lf() +                       // signedResource (blob)
            '' + Lf() +                        // signedSnapshotTime
            '' + Lf() +                        // signedEncryptionScope
            '' + Lf() +                        // rscc  (Cache-Control)
            '' + Lf() +                        // rscd  (Content-Disposition)
            '' + Lf() +                        // rsce  (Content-Encoding)
            '' + Lf() +                        // rscl  (Content-Language)
            '';                                // rsct  (Content-Type) — no trailing newline

        Signature := Sign(StringToSign);

        exit(
            'sv=' + EscapeField(SignedVersionTok) +
            '&spr=https' +
            '&st=' + EscapeField(St) +
            '&se=' + EscapeField(Se) +
            '&sr=b' +
            '&sp=r' +
            '&sig=' + EscapeField(Signature));
    end;

    // Azure's SAS time form, yyyy-MM-ddTHH:mm:ssZ, in UTC. Format(Dt, 0, 9) is the XML/ISO 8601 form,
    // which BC always renders in UTC with a Z suffix (possibly with fractional seconds, which Azure's
    // canonical SAS form does not use) — unlike a picture string, which renders in the SESSION time zone.
    // The first 19 characters are the date-time proper; the fraction and zone are replaced by 'Z'.
    procedure FormatSasTime(Dt: DateTime): Text
    begin
        exit(CopyStr(Format(Dt, 0, 9), 1, 19) + 'Z');
    end;

    // TTL minutes -> Duration, computed in BigInteger: Integer minutes * 60000 overflows past 35791.
    procedure SasTtl(Minutes: Integer): Duration
    var
        Ms: BigInteger;
    begin
        Ms := Minutes;
        Ms := Ms * 60000;
        exit(Ms);
    end;

    local procedure ClockSkewAllowance(): Duration
    begin
        exit(15 * 60000); // 15 minutes: Azure rejects a token whose st is ahead of its own clock
    end;

    local procedure Sign(StringToSign: Text): Text
    var
        CryptoMgt: Codeunit "Cryptography Management";
        AccountKey: SecretText;
        HashAlg: Option HMACMD5,HMACSHA1,HMACSHA256,HMACSHA384,HMACSHA512;
    begin
        GetAccountKey(AccountKey);
        // GenerateBase64KeyedHashAsBase64String: Key is the Base64 account key, input is the plain
        // UTF-8 string-to-sign, output is the Base64 signature — exactly Azure's HMAC-SHA256 SAS sig.
        exit(CryptoMgt.GenerateBase64KeyedHashAsBase64String(StringToSign, AccountKey, HashAlg::HMACSHA256));
    end;

    [NonDebuggable]
    local procedure GetAccountKey(var AccountKey: SecretText): Boolean
    begin
        exit(IsolatedStorage.Get(CredKeyLbl, DataScope::Company, AccountKey));
    end;

    local procedure EscapeField(Value: Text): Text
    var
        UriHelper: Codeunit Uri;
    begin
        exit(UriHelper.EscapeDataString(Value));
    end;

    local procedure Lf(): Text
    var
        C: Char;
    begin
        C := 10;
        exit(Format(C));
    end;
}
