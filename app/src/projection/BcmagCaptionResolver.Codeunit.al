codeunit 94124 "Bcmag Caption Resolver"
{
    // Builds a captionML map keyed by BC language code (ENU, DAN, DEU, ...). For each code
    // it switches GlobalLanguage and re-reads the metadata caption, then restores the
    // original language. Codes that don't resolve fall back to the current language.

    var
        Problem: Codeunit "Bcmag Problem";
        JsonRead: Codeunit "Bcmag Json Read";
        // Code -> LCID (0 = unknown), resolved once per codeunit instance: every caption read
        // switches language per code, and a describe of a wide table does that per field.
        LcidCache: Dictionary of [Text, Integer];

    procedure ParseLanguages(Csv: Text) Codes: List of [Text]
    var
        Parts: List of [Text];
        Part: Text;
    begin
        Parts := Csv.Split(',');
        foreach Part in Parts do begin
            Part := DelChr(Part, '<>', ' ');
            // Dedupe: a repeated code (e.g. languages:["ENU","ENU"]) would make the caption
            // JsonObject.Add throw a duplicate-key error and surface as a 500 instead of a result.
            if (Part <> '') and (not Codes.Contains(Part)) then
                Codes.Add(Part);
        end;
        if Codes.Count() = 0 then
            Codes.Add('ENU');
    end;

    // Each requested language costs a GlobalLanguage switch and a metadata read per caption (per
    // field, per option member), so the list is capped.
    procedure MaxLanguages(): Integer
    begin
        exit(5);
    end;

    // Validating form of LanguagesFrom: every element must be a string (a typed 400 naming
    // languages[] otherwise — never an AsValue() raise surfacing as a 500), and more than
    // MaxLanguages distinct codes is a 400. Absent or empty -> the Default list.
    procedure ReadLanguages(Data: JsonObject; Default: Text; var Codes: List of [Text]; var Fail: JsonObject): Boolean
    var
        Tok: JsonToken;
        Arr: JsonArray;
        i: Integer;
        Csv, Code: Text;
    begin
        Clear(Codes);
        if Data.Get('languages', Tok) then begin
            if not JsonRead.ReadArray(Tok, 'languages', Arr, Fail) then exit(false);
            for i := 0 to Arr.Count() - 1 do begin
                Arr.Get(i, Tok);
                if not JsonRead.ReadText(Tok, 'languages[]', Code, Fail) then exit(false);
                if Code.Contains(',') then begin
                    Fail := Problem.NewFailure(400, 'invalid-field', 'Invalid languages',
                        'each data.languages entry is one language code (e.g. "ENU" or "en-US"), not a comma list');
                    exit(false);
                end;
                if Csv = '' then Csv := Code else Csv += ',' + Code;
            end;
        end;
        if Csv = '' then begin
            // The admin's default list is trusted configuration, not caller input — not capped.
            Codes := ParseLanguages(Default);
            exit(true);
        end;
        Codes := ParseLanguages(Csv);
        if Codes.Count() > MaxLanguages() then begin
            Fail := Problem.NewFailure(400, 'invalid-field', 'Too many languages',
                StrSubstNo('data.languages names %1 languages; at most %2 are resolved per call', Codes.Count(), MaxLanguages()));
            exit(false);
        end;
        exit(true);
    end;

    procedure LanguagesFrom(Data: JsonObject; Default: Text) Codes: List of [Text]
    var
        Tok: JsonToken;
        Arr: JsonArray;
        i: Integer;
        Csv: Text;
    begin
        if Data.Get('languages', Tok) and Tok.IsArray() then begin
            Arr := Tok.AsArray();
            for i := 0 to Arr.Count() - 1 do begin
                Arr.Get(i, Tok);
                if Csv = '' then Csv := Tok.AsValue().AsText() else Csv += ',' + Tok.AsValue().AsText();
            end;
        end;
        if Csv = '' then Csv := Default;
        Codes := ParseLanguages(Csv);
    end;

    procedure ObjectCaptions(ObjectType: Option; ObjectId: Integer; Codes: List of [Text]) Captions: JsonObject
    var
        Code, Caption: Text;
        SavedLang: Integer;
    begin
        SavedLang := GlobalLanguage();
        foreach Code in Codes do
            // Read each caption inside a guarded helper that always restores the language,
            // so a failed metadata read can never leave the session in another language.
            if TryReadObjectCaption(ObjectType, ObjectId, Code, SavedLang, Caption) then
                Captions.Add(Code, Caption);
        GlobalLanguage(SavedLang);
    end;

    procedure FieldCaption(TableId: Integer; FieldNo: Integer; Codes: List of [Text]) Captions: JsonObject
    var
        Code, Caption: Text;
        SavedLang: Integer;
    begin
        SavedLang := GlobalLanguage();
        foreach Code in Codes do
            if TryReadFieldCaption(TableId, FieldNo, Code, SavedLang, Caption) then
                Captions.Add(Code, Caption);
        GlobalLanguage(SavedLang);
    end;

    // For an Option/Enum field, returns [{ ord, name, captionML }] — the ordinal and the
    // language-invariant member name (matching the data plane's {ord,name}) plus the localized
    // caption per requested language. Uses the enum FieldRef metadata (1-based index) under the
    // same guarded GlobalLanguage switch as the caption helpers, so a failed read can never leave
    // the session in another language. FieldRef is passed by value so callers can hand in
    // RecRef.Field(No) directly.
    procedure OptionMemberCaptions(FieldRef: FieldRef; Codes: List of [Text]) Members: JsonArray
    var
        Member: JsonObject;
        SavedLang: Integer;
        i: Integer;
    begin
        SavedLang := GlobalLanguage();
        for i := 1 to FieldRef.EnumValueCount() do begin
            Clear(Member);
            Member.Add('ord', FieldRef.GetEnumValueOrdinal(i));
            Member.Add('name', FieldRef.GetEnumValueName(i));
            Member.Add('captionML', MemberCaptionML(FieldRef, i, Codes, SavedLang));
            Members.Add(Member);
        end;
        GlobalLanguage(SavedLang);
    end;

    local procedure MemberCaptionML(FieldRef: FieldRef; Index: Integer; Codes: List of [Text]; SavedLang: Integer) CaptionML: JsonObject
    var
        Code, Caption: Text;
    begin
        foreach Code in Codes do
            if TryReadEnumCaption(FieldRef, Index, Code, SavedLang, Caption) then
                CaptionML.Add(Code, Caption);
    end;

    [TryFunction]
    local procedure TryReadEnumCaption(FieldRef: FieldRef; Index: Integer; Code: Text; SavedLang: Integer; var Caption: Text)
    begin
        ApplyLanguage(Code, SavedLang);
        Caption := FieldRef.GetEnumValueCaption(Index);
        GlobalLanguage(SavedLang);
    end;

    [TryFunction]
    local procedure TryReadObjectCaption(ObjectType: Option; ObjectId: Integer; Code: Text; SavedLang: Integer; var Caption: Text)
    var
        AllObj: Record AllObjWithCaption;
    begin
        ApplyLanguage(Code, SavedLang);
        if AllObj.Get(ObjectType, ObjectId) then
            Caption := AllObj."Object Caption";
        GlobalLanguage(SavedLang);
    end;

    [TryFunction]
    local procedure TryReadFieldCaption(TableId: Integer; FieldNo: Integer; Code: Text; SavedLang: Integer; var Caption: Text)
    var
        FieldRec: Record Field;
    begin
        ApplyLanguage(Code, SavedLang);
        if FieldRec.Get(TableId, FieldNo) then
            Caption := FieldRec."Field Caption";
        GlobalLanguage(SavedLang);
    end;

    local procedure ApplyLanguage(Code: Text; SavedLang: Integer)
    var
        LangId: Integer;
    begin
        LangId := LanguageIdFromCode(Code);
        if LangId <> 0 then
            GlobalLanguage(LangId)
        else
            GlobalLanguage(SavedLang);
    end;

    // Map a language code to its Windows LCID via the platform "Windows Language" virtual table.
    // Accepts BOTH a BC abbreviated code (ENU, DAN, DEU, ...) via "Abbreviated Name" AND an IETF
    // culture tag (en-US, da-DK, ...) via "Language Tag" — so the shipped 'en-US' default and
    // tag-style caller input resolve instead of silently falling back to the session language.
    // Using the virtual table avoids a dependency on Base Application codeunit 43 "Language"
    // (not referenced — the app depends on System Application only — so it was missing: AL0185).
    // An unknown code returns 0 and the caller keeps the current language.
    local procedure LanguageIdFromCode(Code: Text): Integer
    var
        LangId: Integer;
    begin
        if Code = '' then
            exit(0);
        if LcidCache.Get(Code, LangId) then
            exit(LangId);
        LangId := LookupLanguageId(Code);
        LcidCache.Set(Code, LangId);
        exit(LangId);
    end;

    local procedure LookupLanguageId(Code: Text): Integer
    var
        WindowsLanguage: Record "Windows Language";
    begin
        WindowsLanguage.SetRange("Abbreviated Name", CopyStr(UpperCase(Code), 1, MaxStrLen(WindowsLanguage."Abbreviated Name")));
        if WindowsLanguage.FindFirst() then
            exit(WindowsLanguage."Language ID");
        // Filters are case-insensitive, so 'en-US' / 'EN-US' both match the stored tag.
        WindowsLanguage.SetRange("Abbreviated Name");
        WindowsLanguage.SetRange("Language Tag", CopyStr(Code, 1, MaxStrLen(WindowsLanguage."Language Tag")));
        if WindowsLanguage.FindFirst() then
            exit(WindowsLanguage."Language ID");
        exit(0);
    end;
}
