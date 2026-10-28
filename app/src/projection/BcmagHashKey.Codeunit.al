codeunit 94152 "Bcmag Hash Key"
{
    // Tenant-local HMAC key for values the caller must not be able to confirm by guessing: the strong
    // ETag's field-value hash and the Hash mask kind. An unkeyed SHA-256 of a low-entropy hidden value
    // (a PIN, a short code) can be brute-forced offline from the token alone; the key stays inside the
    // tenant, so the digest only has meaning to this tenant.
    //
    // Stored as plain Text in company-scoped IsolatedStorage: a SecretText value can never be read back
    // as Text on SaaS, and the key is only ever handed on as SecretText. Created on first use.
    // Rotating it (deleting the entry) invalidates outstanding strong ETags and changes every Hash mask
    // value — acceptable, both are re-read on the next call.

    //
    // Seeded at install/upgrade (EnsureKey) so no request path creates it; GetKey still creates it lazily
    // as a fallback. The key is cached for the instance, so callers hold this codeunit as a global and a
    // request does one IsolatedStorage read, not one per row per field.

    var
        CachedKey: SecretText;
        HasCachedKey: Boolean;
        StorageKeyTok: Label 'BCMAG-HASH-KEY', Locked = true;

    [NonDebuggable]
    procedure GetKey(): SecretText
    var
        KeyText: Text;
    begin
        if HasCachedKey then
            exit(CachedKey);
        if not IsolatedStorage.Get(StorageKeyTok, DataScope::Company, KeyText) then begin
            KeyText := NewKeyText();
            IsolatedStorage.Set(StorageKeyTok, KeyText, DataScope::Company);
        end;
        CachedKey := KeyText;
        HasCachedKey := true;
        exit(CachedKey);
    end;

    // Idempotent: creates the key only when absent. Called from install/upgrade.
    [NonDebuggable]
    procedure EnsureKey()
    begin
        if not IsolatedStorage.Contains(StorageKeyTok, DataScope::Company) then
            IsolatedStorage.Set(StorageKeyTok, NewKeyText(), DataScope::Company);
    end;

    // Lowercase hex HMAC-SHA256 of Input under the tenant key.
    [NonDebuggable]
    procedure Hmac(Input: Text): Text
    var
        CryptographyMgt: Codeunit "Cryptography Management";
        HashAlgorithm: Option HMACMD5,HMACSHA1,HMACSHA256,HMACSHA384,HMACSHA512;
    begin
        exit(LowerCase(CryptographyMgt.GenerateHash(Input, GetKey(), HashAlgorithm::HMACSHA256)));
    end;

    // 64 hex chars from two GUIDs (32 hex digits each, braces and dashes stripped).
    [NonDebuggable]
    local procedure NewKeyText(): Text
    begin
        exit(LowerCase(DelChr(Format(CreateGuid()), '=', '{}-') + DelChr(Format(CreateGuid()), '=', '{}-')));
    end;
}
