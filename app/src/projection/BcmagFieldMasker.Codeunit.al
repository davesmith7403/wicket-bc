codeunit 94151 "Bcmag Field Masker"
{
    // Renders the value a Masked caller sees, from a mask profile. MaskText is a pure function of
    // (value, profile): the projector uses it for reads and the write guard uses it to recognise a
    // client echoing a masked value back, so both must agree character for character.
    //
    // Rules never reveal more than the profile's Min Hidden allows: a value too short to hide at least
    // that many characters is masked in full. Unless Preserve Length is on, the hidden run is a fixed
    // four mask chars so the output does not leak the real length.
    //
    // A blank or unknown profile code falls back to the built-in PARTIAL shape (keep last 2, hide at
    // least 4, '*', no length preservation) without needing the PARTIAL row, so a missing or deleted
    // profile can never degrade to Clear.
    //
    // Each profile is loaded once per instance and kept in dictionaries keyed by code. Hash tokens are
    // memoised per distinct input for the instance's life (one HMAC per value, not per cell); the memo is
    // bounded, and an owner that resets the masker (Clear) resets it too.
    //
    // Hash never renders on a Boolean or Option/Enum field: a deterministic token over a handful of
    // possible values splits rows into recognisable groups (know one row's value, know them all), so
    // such a field renders null under Hash and describe reports it as kind "null" with its own type.

    var
        HashKey: Codeunit "Bcmag Hash Key";
        // Profiles resolved once per code per instance (an unknown code is stored with the built-in
        // PARTIAL values, so a missing row is not looked up again either).
        CacheKind: Dictionary of [Code[20], Integer];
        CacheKeepFirst: Dictionary of [Code[20], Integer];
        CacheKeepLast: Dictionary of [Code[20], Integer];
        CacheMinHidden: Dictionary of [Code[20], Integer];
        CacheMaskChar: Dictionary of [Code[20], Text];
        CachePreserve: Dictionary of [Code[20], Boolean];
        CacheFixedText: Dictionary of [Code[20], Text];
        LoadedCode: Code[20];
        IsLoaded: Boolean;
        CurKind: Enum "Bcmag Mask Kind";
        CurKeepFirst: Integer;
        CurKeepLast: Integer;
        CurMinHidden: Integer;
        CurMaskChar: Text[1];
        CurPreserveLength: Boolean;
        CurFixedText: Text;
        HashPrefixTok: Label 'h:', Locked = true;
        HashMemo: Dictionary of [Text, Text];

    procedure MaskText(Value: Text; ProfileCode: Code[20]): Text
    var
        Len: Integer;
    begin
        LoadProfile(ProfileCode);
        if Value = '' then
            exit('');
        Len := StrLen(Value);
        case CurKind of
            CurKind::KeepLast:
                exit(KeepMask(Value, Len, 0, CurKeepLast));
            CurKind::KeepFirst:
                exit(KeepMask(Value, Len, CurKeepFirst, 0));
            CurKind::KeepFirstLast:
                exit(KeepMask(Value, Len, CurKeepFirst, CurKeepLast));
            CurKind::Email:
                exit(EmailMask(Value, Len));
            CurKind::Fixed:
                exit(CurFixedText);
            CurKind::Hash:
                exit(HashToken(Value));
            else
                exit('');
        end;
    end;

    // Writes Name into Target as the masked rendering of the field's current value. Text/Code fields
    // follow MaskText. Every other type has no sensible partial form: Hash and Fixed still render
    // (as strings — see EmittedTypeName), except Hash on a Boolean or Option/Enum field, which renders
    // JSON null (a small domain would re-identify rows); every other kind renders JSON null.
    procedure AddMaskedValue(var Target: JsonObject; Name: Text; FieldRef: FieldRef; ProfileCode: Code[20])
    var
        NullVal: JsonValue;
        TextValue: Text;
    begin
        LoadProfile(ProfileCode);
        NullVal.SetValueToNull();
        if IsTextType(FieldRef.Type) then begin
            if CurKind = CurKind::Null then begin
                Target.Add(Name, NullVal);
                exit;
            end;
            TextValue := FieldRef.Value;
            Target.Add(Name, MaskText(TextValue, ProfileCode));
            exit;
        end;
        case CurKind of
            CurKind::Hash:
                if IsSmallDomainType(FieldRef.Type) then
                    Target.Add(Name, NullVal)
                else
                    Target.Add(Name, HashToken(Format(FieldRef.Value, 0, 9)));
            CurKind::Fixed:
                Target.Add(Name, CurFixedText);
            else
                Target.Add(Name, NullVal);
        end;
    end;

    // The describe/schema type for a masked field: Hash and Fixed turn a non-text field into a string.
    procedure EmittedTypeName(FieldType: FieldType; ProfileCode: Code[20]; OriginalTypeName: Text): Text
    begin
        LoadProfile(ProfileCode);
        if IsTextType(FieldType) then
            exit(OriginalTypeName);
        if CurKind = CurKind::Fixed then
            exit('string');
        if CurKind = CurKind::Hash then
            if not IsSmallDomainType(FieldType) then
                exit('string');
        exit(OriginalTypeName);
    end;

    // The kind a field of this type actually renders with: KindName, except that Hash on a Boolean or
    // Option/Enum field renders null (see the header), so describe reports "null" there.
    procedure EffectiveKindName(FieldType: FieldType; ProfileCode: Code[20]): Text
    begin
        LoadProfile(ProfileCode);
        if CurKind = CurKind::Hash then
            if IsSmallDomainType(FieldType) then
                exit('null');
        exit(KindName(ProfileCode));
    end;

    // Invariant wire name of the profile's kind (explicit map: Format(enum) is a locale-dependent caption).
    procedure KindName(ProfileCode: Code[20]): Text
    begin
        LoadProfile(ProfileCode);
        case CurKind of
            CurKind::KeepLast:
                exit('keepLast');
            CurKind::KeepFirst:
                exit('keepFirst');
            CurKind::KeepFirstLast:
                exit('keepFirstLast');
            CurKind::Email:
                exit('email');
            CurKind::Fixed:
                exit('fixed');
            CurKind::Null:
                exit('null');
            CurKind::Hash:
                exit('hash');
        end;
        exit('keepLast');
    end;

    // ---- rendering helpers -----------------------------------------------------------------------

    local procedure KeepMask(Value: Text; Len: Integer; KeepFirst: Integer; KeepLast: Integer): Text
    var
        Hidden: Integer;
    begin
        Hidden := Len - KeepFirst - KeepLast;
        if Hidden < CurMinHidden then
            exit(FullMask(Len));
        exit(CopyStr(Value, 1, KeepFirst) + Fill(Hidden) + CopyStr(Value, Len - KeepLast + 1));
    end;

    // The first character and the domain are kept; the rest of the local part is hidden. No local part
    // (no '@', or '@' first) leaves nothing to keep, so the whole value is masked. Min Hidden applies to
    // the local part like any other rendering: when keeping its first character would hide fewer than
    // Min Hidden characters, the whole local part is masked and only '@domain' stays — otherwise a
    // one-character local part would come out unmasked and a two-character one would hide a single char.
    local procedure EmailMask(Value: Text; Len: Integer): Text
    var
        AtPos: Integer;
    begin
        AtPos := StrPos(Value, '@');
        if AtPos <= 1 then
            exit(FullMask(Len));
        if AtPos - 2 < CurMinHidden then
            exit(FullMask(AtPos - 1) + CopyStr(Value, AtPos));
        exit(CopyStr(Value, 1, 1) + Fill(AtPos - 2) + CopyStr(Value, AtPos));
    end;

    local procedure Fill(Hidden: Integer): Text
    begin
        if CurPreserveLength then
            exit(MaskRun(Hidden));
        exit(MaskRun(4));
    end;

    local procedure FullMask(Len: Integer): Text
    begin
        if CurPreserveLength then
            exit(MaskRun(Len));
        exit(MaskRun(4));
    end;

    local procedure MaskRun(Count: Integer): Text
    begin
        if Count <= 0 then
            exit('');
        exit(PadStr('', Count, CurMaskChar));
    end;

    local procedure IsTextType(FieldType: FieldType): Boolean
    begin
        exit((FieldType = FieldType::Text) or (FieldType = FieldType::Code));
    end;

    // Boolean and Option (an Enum field reports Option through FieldRef.Type): too few values for a
    // deterministic token to hide anything.
    local procedure IsSmallDomainType(FieldType: FieldType): Boolean
    begin
        exit((FieldType = FieldType::Boolean) or (FieldType = FieldType::Option));
    end;

    // 'h:' + the first 16 hex characters of the keyed HMAC, memoised per distinct input. The memo is
    // cleared when it reaches 1000 entries, so a long-lived instance over a large export stays bounded.
    local procedure HashToken(Value: Text) Token: Text
    begin
        if HashMemo.Get(Value, Token) then
            exit;
        Token := HashPrefixTok + CopyStr(HashKey.Hmac(Value), 1, 16);
        if HashMemo.Count() >= 1000 then
            Clear(HashMemo);
        HashMemo.Add(Value, Token);
    end;

    local procedure LoadProfile(ProfileCode: Code[20])
    var
        Profile: Record "Bcmag Mask Profile";
        Kind: Enum "Bcmag Mask Kind";
        KeepFirst, KeepLast, MinHidden : Integer;
        MaskChar, FixedText : Text;
        Preserve: Boolean;
    begin
        if IsLoaded and (LoadedCode = ProfileCode) then
            exit;
        if not CacheKind.ContainsKey(ProfileCode) then begin
            // Built-in PARTIAL shape; overwritten when the profile row exists.
            Kind := Kind::KeepLast;
            KeepFirst := 0;
            KeepLast := 2;
            MinHidden := 4;
            MaskChar := '*';
            Preserve := false;
            FixedText := '[redacted]';
            if ProfileCode <> '' then
                if Profile.Get(ProfileCode) then begin
                    Kind := Profile.Kind;
                    KeepFirst := Profile."Keep First";
                    KeepLast := Profile."Keep Last";
                    MinHidden := Profile."Min Hidden";
                    Preserve := Profile."Preserve Length";
                    FixedText := Profile."Fixed Text";
                    if Profile."Mask Char" <> '' then
                        MaskChar := Profile."Mask Char";
                end;
            // The table's MinValue = 1 and the Fixed Text InitValue are enforced only through Validate and
            // Init: a row written by code or a configuration package can hold 0 or a blank. Min Hidden 0
            // would let a short value render in full (KeepLast 2 on "12" → "****12"), and a blank Fixed
            // Text would read as an empty field (and make the write guard refuse a deliberate '').
            if MinHidden < 1 then
                MinHidden := 1;
            if FixedText = '' then
                FixedText := '[redacted]';
            CacheKind.Add(ProfileCode, Kind.AsInteger());
            CacheKeepFirst.Add(ProfileCode, KeepFirst);
            CacheKeepLast.Add(ProfileCode, KeepLast);
            CacheMinHidden.Add(ProfileCode, MinHidden);
            CacheMaskChar.Add(ProfileCode, MaskChar);
            CachePreserve.Add(ProfileCode, Preserve);
            CacheFixedText.Add(ProfileCode, FixedText);
        end;
        CurKind := Enum::"Bcmag Mask Kind".FromInteger(CacheKind.Get(ProfileCode));
        CurKeepFirst := CacheKeepFirst.Get(ProfileCode);
        CurKeepLast := CacheKeepLast.Get(ProfileCode);
        CurMinHidden := CacheMinHidden.Get(ProfileCode);
        CurMaskChar := CopyStr(CacheMaskChar.Get(ProfileCode), 1, 1);
        CurPreserveLength := CachePreserve.Get(ProfileCode);
        CurFixedText := CacheFixedText.Get(ProfileCode);
        LoadedCode := ProfileCode;
        IsLoaded := true;
    end;
}
