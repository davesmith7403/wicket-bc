codeunit 94129 "Bcmag Field Policy"
{
    // Field-level read/write policy layered on top of the table-level exposure allowlist. BC has
    // no native per-column security, so every surface that RESOLVES a field (select/selectFieldNo,
    // "*" expansion, filter, orderBy, readBlob, insert/modify values, describe) asks this codeunit
    // once per field per request — never per row inside a projection loop. The model:
    //   AllFields        — v1.1 back-compat: every field Clear and writable; override rows are
    //                      IGNORED so upgrades cannot silently change behavior.
    //   ByClassification — the field's DataClassification maps to a "Bcmag Classification Rule"
    //                      (row, else the built-in default in "Bcmag Policy Defaults");
    //                      "Bcmag Field Exposure" rows override individual fields either way.
    //   Explicit         — only fields with an override row are accessible (fail-closed).
    // Reading is a three-way verdict (Hidden / Masked / Clear) resolved PER PRINCIPAL — the plan's
    // normative "Verdict precedence":
    //   baseline  := field row, else Hidden (Explicit), else the classification rule
    //   principal := baseline, replaced by the caller's active field-scope exception, else by the
    //                caller's active classification-scope exception; then — only when NO exception
    //                matched the field — Masked → Clear when the Unmask tier is enabled in Setup and
    //                the caller holds it. A per-user exception that decided the field is final: the
    //                tier never overrides an administrator's targeted row, and never lifts Hidden.
    //   final     := principal, or MoreRestrictive(baseline, principal) when the request carries
    //                "unmask": false — the opt-out can tighten, never widen
    //   a final verdict more permissive than the baseline is noted as a lift (Op Runner Context).
    // Writability ignores exceptions and the tier: field row → Allow Write; Explicit without a row →
    // no; classification → only when the baseline verdict is Clear.
    //
    // Caching: one instance answers many fields of one request, so it loads Setup, the caller's
    // exceptions and the tier check ONCE, each rule row at most once, and every field's verdict once
    // ('<table>:<field>' keys), and each mask profile's kind at most once. The cache is tied to the Op Runner Context's policy generation, which
    // moves on every new request and every in-session policy write — so a long-lived instance (a
    // handler held as a global) never answers from a stale policy.
    // Primary-key fields are ALWAYS readable and writable: they address rows (@recordId, describe
    // primaryKey) and seed inserts, and denying them would break the plane without hiding data a
    // caller could not already infer from record identity.
    // Known limitation: a FlowField is judged by its OWN DataClassification — a FlowField that
    // aggregates or looks up a restricted base field is NOT derived-restricted in v1. Classify
    // (or add a deny row for) the FlowField itself when its computed result is sensitive.

    var
        PolicyCtx: Codeunit "Bcmag Op Runner Context";
        PolicyDefaults: Codeunit "Bcmag Policy Defaults";
        CachedPkTableId: Integer;
        CachedPkFields: List of [Integer];
        // ---- per-instance cache, valid while CacheGeneration is the context's current generation ----
        CacheLoaded: Boolean;
        CacheGeneration: Integer;
        PolicyMode: Enum "Bcmag Field Policy Mode";
        TierEnabled: Boolean;
        UnmaskFlag: Boolean;
        UnmaskChecked: Boolean;
        UnmaskHeld: Boolean;
        ExceptionsLoaded: Boolean;
        ExceptionCount: Integer;
        ExcAccessByField: Dictionary of [Text, Integer];
        ExcProfileByField: Dictionary of [Text, Text];
        ExcAccessByClass: Dictionary of [Integer, Integer];
        ExcProfileByClass: Dictionary of [Integer, Text];
        RuleAccessByClass: Dictionary of [Integer, Integer];
        RuleProfileByClass: Dictionary of [Integer, Text];
        ProfileRankByCode: Dictionary of [Text, Integer];
        VerdictByField: Dictionary of [Text, Integer];
        ProfileByField: Dictionary of [Text, Text];
        WritableByField: Dictionary of [Text, Boolean];
        LiftedByField: Dictionary of [Text, Boolean];
        StrictByField: Dictionary of [Text, Integer];
        StrictProfileByField: Dictionary of [Text, Text];
        BaselineByField: Dictionary of [Text, Integer];
        BaselineProfileByField: Dictionary of [Text, Text];

    // ---- public surface --------------------------------------------------------------------------

    // The caller's read verdict for one field. ProfileCode is the mask profile when the verdict is
    // Masked ('' = the built-in partial mask), and '' for Hidden and Clear.
    procedure ReadVerdict(TableId: Integer; FieldNo: Integer; var ProfileCode: Code[20]): Enum "Bcmag Read Access"
    var
        FieldKey: Text;
    begin
        FieldKey := ResolveForRead(TableId, FieldNo);
        ProfileCode := CopyStr(ProfileByField.Get(FieldKey), 1, MaxStrLen(ProfileCode));
        exit(VerdictOf(FieldKey));
    end;

    // The verdict this caller gets under "unmask": false — MoreRestrictive(baseline, principal), with the
    // ranked profile — whatever the CURRENT request's flag says. The write guard needs it: a caller who
    // holds a lift may have read the field masked under the opt-out in an earlier request, and an echo of
    // that rendering must be recognised even when the write itself carries no opt-out. Never a lift, so
    // nothing is noted for the Operation Log.
    procedure StrictReadVerdict(TableId: Integer; FieldNo: Integer; var ProfileCode: Code[20]): Enum "Bcmag Read Access"
    var
        FieldKey: Text;
    begin
        FieldKey := Resolve(TableId, FieldNo);
        ProfileCode := CopyStr(StrictProfileByField.Get(FieldKey), 1, MaxStrLen(ProfileCode));
        exit(Enum::"Bcmag Read Access".FromInteger(StrictByField.Get(FieldKey)));
    end;

    // The field's baseline (field row, Explicit default or classification rule) before the caller's
    // exceptions and the Unmask tier. Same caching; never a lift.
    procedure BaselineReadVerdict(TableId: Integer; FieldNo: Integer; var ProfileCode: Code[20]): Enum "Bcmag Read Access"
    var
        FieldKey: Text;
    begin
        FieldKey := Resolve(TableId, FieldNo);
        ProfileCode := CopyStr(BaselineProfileByField.Get(FieldKey), 1, MaxStrLen(ProfileCode));
        exit(Enum::"Bcmag Read Access".FromInteger(BaselineByField.Get(FieldKey)));
    end;

    // Hidden is the only unreadable verdict: a Masked field is emitted, as its mask rendering.
    procedure IsReadable(TableId: Integer; FieldNo: Integer): Boolean
    begin
        exit(Allowed(TableId, FieldNo, false));
    end;

    procedure IsClear(TableId: Integer; FieldNo: Integer): Boolean
    begin
        exit(VerdictOf(ResolveForRead(TableId, FieldNo)) = "Bcmag Read Access"::Clear);
    end;

    procedure IsMasked(TableId: Integer; FieldNo: Integer): Boolean
    begin
        exit(VerdictOf(ResolveForRead(TableId, FieldNo)) = "Bcmag Read Access"::Masked);
    end;

    procedure IsWritable(TableId: Integer; FieldNo: Integer): Boolean
    begin
        exit(Allowed(TableId, FieldNo, true));
    end;

    // Marker prefix for the filter applier's text ErrorMsg channel: the applier cannot return a
    // typed problem, so it prefixes a policy denial with this marker and the query handler maps
    // marked messages to 403 'field-restricted' instead of 400 'invalid-filter' (analogous to the
    // existing 'did you mean "..."' suggestion marker the query handler already extracts).
    procedure RestrictedMarker(): Text
    begin
        exit('[field-restricted] ');
    end;

    // The same channel for a field that is readable only masked: filtering, ordering or aggregating
    // on it would turn row membership into an oracle for the hidden value, so the handler maps this
    // marker to 403 'field-masked'.
    procedure MaskedMarker(): Text
    begin
        exit('[field-masked] ');
    end;

    // Whether the caller holds the Unmask tier right now: Setup "Unmask Tier Enabled" AND write
    // permission on the "Bcmag Unmask Gate" sentinel (only "Wicket - Unmask" grants it). Checked once
    // per instance and generation.
    procedure UnmaskGranted(): Boolean
    var
        UnmaskGate: Record "Bcmag Unmask Gate";
    begin
        EnsureFresh();
        if not UnmaskChecked then begin
            UnmaskHeld := false;
            if TierEnabled then
                UnmaskHeld := UnmaskGate.WritePermission();
            UnmaskChecked := true;
        end;
        exit(UnmaskHeld);
    end;

    // The number of the caller's exception rows active right now (capabilities / whoAmI).
    procedure ActiveExceptionCount(): Integer
    begin
        EnsureFresh();
        LoadExceptions();
        exit(ExceptionCount);
    end;

    // ---- resolution ------------------------------------------------------------------------------

    local procedure Allowed(TableId: Integer; FieldNo: Integer; ForWrite: Boolean): Boolean
    var
        FieldKey: Text;
    begin
        if ForWrite then begin
            FieldKey := Resolve(TableId, FieldNo);
            exit(WritableByField.Get(FieldKey));
        end;
        exit(VerdictOf(ResolveForRead(TableId, FieldNo)) <> "Bcmag Read Access"::Hidden);
    end;

    // A read-side answer: a lifted verdict is noted for the Operation Log here — not in Resolve —
    // so a write that only asks IsWritable never records a lift it did not read. NoteLift is
    // in-memory and distinct; this runs once per field per policy call, never per row.
    local procedure ResolveForRead(TableId: Integer; FieldNo: Integer) FieldKey: Text
    begin
        FieldKey := Resolve(TableId, FieldNo);
        if LiftedByField.Get(FieldKey) then
            PolicyCtx.NoteLift(TableId, FieldNo);
    end;

    local procedure Resolve(TableId: Integer; FieldNo: Integer) FieldKey: Text
    var
        Row: Record "Bcmag Field Exposure";
        FieldRec: Record Field;
        Baseline, Principal, Final: Enum "Bcmag Read Access";
        Strict: Enum "Bcmag Read Access";
        BaseProfile, PrincipalProfile, FinalProfile, StrictProfile: Code[20];
        Writable, FieldLoaded, ExceptionApplied: Boolean;
    begin
        EnsureFresh();
        FieldKey := Format(TableId, 0, 9) + ':' + Format(FieldNo, 0, 9);
        if VerdictByField.ContainsKey(FieldKey) then
            exit;

        if PolicyMode = PolicyMode::AllFields then begin
            Store(FieldKey, "Bcmag Read Access"::Clear, '', true, false);
            exit;
        end;
        if IsPrimaryKeyField(TableId, FieldNo) then begin
            Store(FieldKey, "Bcmag Read Access"::Clear, '', true, false);
            exit;
        end;

        // ---- baseline
        if Row.Get(TableId, FieldNo) then begin
            Baseline := Row."Read Access";
            BaseProfile := Row."Mask Profile";
            Writable := Row."Allow Write";
        end else
            if PolicyMode = PolicyMode::Explicit then begin
                Baseline := Baseline::Hidden;
                Writable := false;
            end else begin
                // ByClassification without an override row: an unresolvable field is fail-closed, and
                // no exception can open a field that does not exist — which also keeps a restricted
                // field indistinguishable from a nonexistent one (no probing).
                if not FieldRec.Get(TableId, FieldNo) then begin
                    Store(FieldKey, "Bcmag Read Access"::Hidden, '', false, false);
                    exit;
                end;
                FieldLoaded := true;
                ClassificationRule(PolicyDefaults.DataClassOf(FieldRec), Baseline, BaseProfile);
                Writable := Baseline = Baseline::Clear;
            end;

        // ---- principal: the caller's exceptions, then the Unmask tier. An exception that matched the
        // field (field- or classification-scope) decides it for good: the tier lifts only a Masked
        // verdict that no exception touched, so a per-user tightening row cannot be undone by a
        // blanket permission set.
        Principal := Baseline;
        PrincipalProfile := BaseProfile;
        LoadExceptions();
        ExceptionApplied := ApplyFieldException(FieldKey, Principal, PrincipalProfile);
        if not ExceptionApplied then
            if ExcAccessByClass.Count() > 0 then begin
                if not FieldLoaded then
                    FieldLoaded := FieldRec.Get(TableId, FieldNo);
                if FieldLoaded then
                    ExceptionApplied := ApplyClassException(PolicyDefaults.DataClassOf(FieldRec), Principal, PrincipalProfile);
            end;
        if not ExceptionApplied then
            if Principal = Principal::Masked then
                if UnmaskGranted() then begin
                    Principal := Principal::Clear;
                    PrincipalProfile := '';
                end;

        // ---- strict (the "unmask": false verdict): the more restrictive of baseline and principal.
        // When both are Masked the PROFILES are ranked too (ProfileRank): an exception that re-masks
        // more strictly (PARTIAL → REDACT) still applies, a looser one (HASH → PARTIAL) does not —
        // either way the opt-out never widens the caller's view. On an equal profile rank the
        // principal's profile stands (the administrator's targeted choice). Computed for every request,
        // because the write guard asks for it whatever the request's own flag is.
        Strict := Principal;
        StrictProfile := PrincipalProfile;
        if Rank(Baseline) < Rank(Principal) then begin
            Strict := Baseline;
            StrictProfile := BaseProfile;
        end else
            if Baseline = Baseline::Masked then
                if Principal = Principal::Masked then
                    if ProfileRank(BaseProfile) > ProfileRank(PrincipalProfile) then
                        StrictProfile := BaseProfile;
        if Strict <> Strict::Masked then
            StrictProfile := '';

        // ---- final: the principal's verdict, or the strict one when the request opts out.
        Final := Principal;
        FinalProfile := PrincipalProfile;
        if not UnmaskFlag then begin
            Final := Strict;
            FinalProfile := StrictProfile;
        end;
        if Final <> Final::Masked then
            FinalProfile := '';
        if Baseline <> Baseline::Masked then
            BaseProfile := '';

        StoreFull(FieldKey, Final, FinalProfile, Writable, Rank(Final) > Rank(Baseline), Strict, StrictProfile, Baseline, BaseProfile);
    end;

    local procedure ApplyFieldException(FieldKey: Text; var Access: Enum "Bcmag Read Access"; var ProfileCode: Code[20]): Boolean
    var
        Ordinal: Integer;
    begin
        if not ExcAccessByField.Get(FieldKey, Ordinal) then
            exit(false);
        Access := Enum::"Bcmag Read Access".FromInteger(Ordinal);
        ProfileCode := CopyStr(ExcProfileByField.Get(FieldKey), 1, MaxStrLen(ProfileCode));
        exit(true);
    end;

    local procedure ApplyClassException(DataClass: Enum "Bcmag Data Class"; var Access: Enum "Bcmag Read Access"; var ProfileCode: Code[20]): Boolean
    var
        Ordinal: Integer;
    begin
        if not ExcAccessByClass.Get(DataClass.AsInteger(), Ordinal) then
            exit(false);
        Access := Enum::"Bcmag Read Access".FromInteger(Ordinal);
        ProfileCode := CopyStr(ExcProfileByClass.Get(DataClass.AsInteger()), 1, MaxStrLen(ProfileCode));
        exit(true);
    end;

    // One rule lookup per classification per instance ("Bcmag Policy Defaults": row, else built-in).
    local procedure ClassificationRule(DataClass: Enum "Bcmag Data Class"; var Access: Enum "Bcmag Read Access"; var ProfileCode: Code[20])
    var
        Ordinal: Integer;
    begin
        if RuleAccessByClass.Get(DataClass.AsInteger(), Ordinal) then begin
            Access := Enum::"Bcmag Read Access".FromInteger(Ordinal);
            ProfileCode := CopyStr(RuleProfileByClass.Get(DataClass.AsInteger()), 1, MaxStrLen(ProfileCode));
            exit;
        end;
        PolicyDefaults.ClassificationRule(DataClass, Access, ProfileCode);
        RuleAccessByClass.Add(DataClass.AsInteger(), Access.AsInteger());
        RuleProfileByClass.Add(DataClass.AsInteger(), ProfileCode);
    end;

    // A field no exception or tier can change (AllFields, primary key, unresolvable): the strict and
    // baseline verdicts are the final one.
    local procedure Store(FieldKey: Text; Access: Enum "Bcmag Read Access"; ProfileCode: Code[20]; Writable: Boolean; Lifted: Boolean)
    begin
        StoreFull(FieldKey, Access, ProfileCode, Writable, Lifted, Access, ProfileCode, Access, ProfileCode);
    end;

    local procedure StoreFull(FieldKey: Text; Access: Enum "Bcmag Read Access"; ProfileCode: Code[20]; Writable: Boolean; Lifted: Boolean; Strict: Enum "Bcmag Read Access"; StrictProfile: Code[20]; Baseline: Enum "Bcmag Read Access"; BaseProfile: Code[20])
    begin
        VerdictByField.Add(FieldKey, Access.AsInteger());
        ProfileByField.Add(FieldKey, ProfileCode);
        WritableByField.Add(FieldKey, Writable);
        LiftedByField.Add(FieldKey, Lifted);
        StrictByField.Add(FieldKey, Strict.AsInteger());
        StrictProfileByField.Add(FieldKey, StrictProfile);
        BaselineByField.Add(FieldKey, Baseline.AsInteger());
        BaselineProfileByField.Add(FieldKey, BaseProfile);
    end;

    local procedure VerdictOf(FieldKey: Text): Enum "Bcmag Read Access"
    begin
        exit(Enum::"Bcmag Read Access".FromInteger(VerdictByField.Get(FieldKey)));
    end;

    // Restrictiveness order, Hidden < Masked < Clear, as an explicit map rather than an assumption
    // about the enum's ordinals. An unknown value ranks as Hidden (fail-closed).
    local procedure Rank(Access: Enum "Bcmag Read Access"): Integer
    begin
        case Access of
            Access::Hidden:
                exit(0);
            Access::Masked:
                exit(1);
            Access::Clear:
                exit(2);
        end;
        exit(0);
    end;

    // How much a mask profile hides, for the "unmask": false tie between two Masked verdicts:
    // Null 5 > Fixed 4 > Hash 3 > Email 2 > KeepFirst / KeepLast / KeepFirstLast 1. A blank or unknown
    // code renders with the built-in partial mask, so it ranks 1. One Get per code per instance.
    local procedure ProfileRank(ProfileCode: Code[20]): Integer
    var
        Profile: Record "Bcmag Mask Profile";
        ProfileRankValue: Integer;
    begin
        if ProfileCode = '' then
            exit(1);
        if ProfileRankByCode.Get(ProfileCode, ProfileRankValue) then
            exit(ProfileRankValue);
        ProfileRankValue := 1;
        if Profile.ReadPermission() then begin
            Profile.SetLoadFields(Kind);
            if Profile.Get(ProfileCode) then
                ProfileRankValue := KindRank(Profile.Kind);
        end;
        ProfileRankByCode.Add(ProfileCode, ProfileRankValue);
        exit(ProfileRankValue);
    end;

    // Explicit map, no assumption about the enum's ordinals; an unknown kind ranks with the partial
    // masks (the masker treats it the same way).
    local procedure KindRank(Kind: Enum "Bcmag Mask Kind"): Integer
    begin
        case Kind of
            Kind::Null:
                exit(5);
            Kind::Fixed:
                exit(4);
            Kind::Hash:
                exit(3);
            Kind::Email:
                exit(2);
            Kind::KeepFirst,
            Kind::KeepLast,
            Kind::KeepFirstLast:
                exit(1);
        end;
        exit(1);
    end;

    // ---- per-instance state ----------------------------------------------------------------------

    local procedure EnsureFresh()
    var
        Setup: Record "Bcmag Setup";
    begin
        if CacheLoaded then
            if CacheGeneration = PolicyCtx.PolicyGeneration() then
                exit;

        Clear(VerdictByField);
        Clear(ProfileByField);
        Clear(WritableByField);
        Clear(LiftedByField);
        Clear(StrictByField);
        Clear(StrictProfileByField);
        Clear(BaselineByField);
        Clear(BaselineProfileByField);
        Clear(RuleAccessByClass);
        Clear(RuleProfileByClass);
        Clear(ProfileRankByCode);
        Clear(ExcAccessByField);
        Clear(ExcProfileByField);
        Clear(ExcAccessByClass);
        Clear(ExcProfileByClass);
        ExceptionsLoaded := false;
        ExceptionCount := 0;
        UnmaskChecked := false;

        Setup.GetSingleton();
        PolicyMode := Setup."Field Policy Mode";
        TierEnabled := Setup."Unmask Tier Enabled";
        UnmaskFlag := PolicyCtx.UnmaskRequested();
        // Read last: GetSingleton's first-ever Insert itself moves the generation.
        CacheGeneration := PolicyCtx.PolicyGeneration();
        CacheLoaded := true;
    end;

    // The caller's exceptions, loaded once per instance and generation into a by-field and a
    // by-classification map. Read defensively — the read path must never raise: an inverted validity
    // window (Until before From) is never active, a field-scope row without a table or field number is
    // ignored, and a caller without read permission on the table simply has no exceptions. Two active
    // rows for the same target resolve to the more restrictive one (deterministic, and never wider
    // than either grant).
    local procedure LoadExceptions()
    var
        ExcRow: Record "Bcmag Access Exception";
        Now: DateTime;
    begin
        if ExceptionsLoaded then
            exit;
        ExceptionsLoaded := true;
        if not ExcRow.ReadPermission() then
            exit;
        Now := CurrentDateTime();
        ExcRow.SetCurrentKey("User Security ID", Scope);
        ExcRow.SetRange("User Security ID", UserSecurityId());
        ExcRow.SetLoadFields(Scope, "Data Class", "Table Id", "Field No.", "Read Access", "Mask Profile", "Valid From", "Valid Until");
        if ExcRow.FindSet() then
            repeat
                if IsActive(ExcRow, Now) then begin
                    ExceptionCount += 1;
                    if ExcRow.Scope = ExcRow.Scope::Field then
                        AddFieldException(Format(ExcRow."Table Id", 0, 9) + ':' + Format(ExcRow."Field No.", 0, 9), ExcRow."Read Access", ExcRow."Mask Profile")
                    else
                        AddClassException(ExcRow."Data Class".AsInteger(), ExcRow."Read Access", ExcRow."Mask Profile");
                end;
            until ExcRow.Next() = 0;
    end;

    local procedure IsActive(ExcRow: Record "Bcmag Access Exception"; Now: DateTime): Boolean
    begin
        if ExcRow."Valid From" <> 0DT then
            if ExcRow."Valid From" > Now then
                exit(false);
        if ExcRow."Valid Until" <> 0DT then
            if ExcRow."Valid Until" < Now then
                exit(false);
        if ExcRow."Valid From" <> 0DT then
            if ExcRow."Valid Until" <> 0DT then
                if ExcRow."Valid Until" < ExcRow."Valid From" then
                    exit(false);
        if ExcRow.Scope = ExcRow.Scope::Field then begin
            if ExcRow."Table Id" = 0 then
                exit(false);
            if ExcRow."Field No." = 0 then
                exit(false);
        end;
        exit(true);
    end;

    local procedure AddFieldException(FieldKey: Text; Access: Enum "Bcmag Read Access"; ProfileCode: Code[20])
    var
        Ordinal: Integer;
    begin
        if ExcAccessByField.Get(FieldKey, Ordinal) then begin
            if Rank(Access) >= Rank(Enum::"Bcmag Read Access".FromInteger(Ordinal)) then
                exit;
            ExcAccessByField.Set(FieldKey, Access.AsInteger());
            ExcProfileByField.Set(FieldKey, ProfileCode);
            exit;
        end;
        ExcAccessByField.Add(FieldKey, Access.AsInteger());
        ExcProfileByField.Add(FieldKey, ProfileCode);
    end;

    local procedure AddClassException(ClassOrdinal: Integer; Access: Enum "Bcmag Read Access"; ProfileCode: Code[20])
    var
        Ordinal: Integer;
    begin
        if ExcAccessByClass.Get(ClassOrdinal, Ordinal) then begin
            if Rank(Access) >= Rank(Enum::"Bcmag Read Access".FromInteger(Ordinal)) then
                exit;
            ExcAccessByClass.Set(ClassOrdinal, Access.AsInteger());
            ExcProfileByClass.Set(ClassOrdinal, ProfileCode);
            exit;
        end;
        ExcAccessByClass.Add(ClassOrdinal, Access.AsInteger());
        ExcProfileByClass.Add(ClassOrdinal, ProfileCode);
    end;

    // PK membership determined the same way OpQuery.UsePrimaryKeyFields does: key 1's
    // comma-separated field-name list matched against FieldName. Cached per table because
    // describe and "*" expansion consult the policy for every field of one table.
    local procedure IsPrimaryKeyField(TableId: Integer; FieldNo: Integer): Boolean
    var
        KeyRec: Record "Key";
        FieldRec: Record Field;
        Parts: List of [Text];
        Part: Text;
    begin
        if TableId <> CachedPkTableId then begin
            Clear(CachedPkFields);
            KeyRec.SetRange(TableNo, TableId);
            KeyRec.SetRange("No.", 1);
            if KeyRec.FindFirst() then begin
                Parts := KeyRec."Key".Split(',');
                foreach Part in Parts do begin
                    FieldRec.SetRange(TableNo, TableId);
                    FieldRec.SetRange(FieldName, DelChr(Part, '<>', ' '));
                    if FieldRec.FindFirst() then
                        CachedPkFields.Add(FieldRec."No.");
                end;
            end;
            CachedPkTableId := TableId;
        end;
        exit(CachedPkFields.Contains(FieldNo));
    end;
}
