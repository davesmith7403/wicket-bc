codeunit 94150 "Bcmag Policy Defaults"
{
    // The shipped field-policy posture and the one classification map.
    //   - BuiltInRule: the verdict a classification gets when no "Bcmag Classification Rule" row
    //     exists. Install and upgrade seed the same values as rows, so an administrator sees (and can
    //     change) them; deleting a row falls back here, never to "open".
    //   - SeedFieldPolicyDefaults: inserts only MISSING rule and profile rows, so it is safe on every
    //     install and upgrade and never overwrites an administrator's choice.
    //   - DataClassOf / ClassName / DataClassNameOf: the explicit case maps between the platform's
    //     Field.DataClassification option, Wicket's "Bcmag Data Class" enum and the invariant wire
    //     names. Format() of an option yields the session-language caption, so it must never stand in
    //     for an identifier; every surface (policy, describe, capabilities) goes through these maps.

    var
        PartialTok: Label 'PARTIAL', Locked = true;
        EmailTok: Label 'EMAIL', Locked = true;
        RedactTok: Label 'REDACT', Locked = true;
        HashTok: Label 'HASH', Locked = true;
        NullTok: Label 'NULL', Locked = true;
        PartialDescTxt: Label 'Keep the last 2 characters', Locked = true;
        EmailDescTxt: Label 'Keep the first letter and the domain', Locked = true;
        RedactDescTxt: Label 'Replace with fixed text', Locked = true;
        HashDescTxt: Label 'Keyed hash (equal values stay equal)', Locked = true;
        NullDescTxt: Label 'Emit null', Locked = true;

    // ---- built-in posture ------------------------------------------------------------------------

    // Fresh-install posture (owner decision 2026-10-04): content and system metadata are clear,
    // end-user identifiers are masked with the partial profile, everything else is hidden.
    procedure BuiltInRule(DataClass: Enum "Bcmag Data Class"; var Access: Enum "Bcmag Read Access"; var ProfileCode: Code[20])
    begin
        ProfileCode := '';
        case DataClass of
            DataClass::CustomerContent,
            DataClass::SystemMetadata:
                Access := Access::Clear;
            DataClass::EndUserIdentifiableInformation,
            DataClass::EndUserPseudonymousIdentifiers:
                begin
                    Access := Access::Masked;
                    ProfileCode := PartialTok;
                end;
            else
                // ToBeClassified, OrganizationIdentifiableInformation, AccountData — and any value a
                // later enum revision might add — stay hidden until an administrator decides.
                Access := Access::Hidden;
        end;
    end;

    procedure SeedFieldPolicyDefaults()
    begin
        SeedProfiles();
        SeedRules();
    end;

    local procedure SeedRules()
    var
        Rule: Record "Bcmag Classification Rule";
        DataClass: Enum "Bcmag Data Class";
        Access: Enum "Bcmag Read Access";
        ProfileCode: Code[20];
        Ordinal: Integer;
    begin
        foreach Ordinal in Enum::"Bcmag Data Class".Ordinals() do begin
            DataClass := Enum::"Bcmag Data Class".FromInteger(Ordinal);
            if not Rule.Get(DataClass) then begin
                BuiltInRule(DataClass, Access, ProfileCode);
                Rule.Init();
                Rule."Data Class" := DataClass;
                Rule."Read Access" := Access;
                Rule."Mask Profile" := ProfileCode;
                Rule.Insert();
            end;
        end;
    end;

    local procedure SeedProfiles()
    var
        Kind: Enum "Bcmag Mask Kind";
    begin
        SeedProfile(PartialTok, PartialDescTxt, Kind::KeepLast, 0, 2);
        SeedProfile(EmailTok, EmailDescTxt, Kind::Email, 0, 0);
        SeedProfile(RedactTok, RedactDescTxt, Kind::Fixed, 0, 0);
        SeedProfile(HashTok, HashDescTxt, Kind::Hash, 0, 0);
        SeedProfile(NullTok, NullDescTxt, Kind::Null, 0, 0);
    end;

    // Min Hidden, Mask Char, Preserve Length and Fixed Text keep their table InitValues (4, '*', off,
    // '[redacted]'), so the seed and a profile an administrator creates by hand start identical.
    local procedure SeedProfile(ProfileCode: Code[20]; Description: Text[100]; Kind: Enum "Bcmag Mask Kind"; KeepFirst: Integer; KeepLast: Integer)
    var
        Profile: Record "Bcmag Mask Profile";
    begin
        if Profile.Get(ProfileCode) then
            exit;
        Profile.Init();
        Profile.Code := ProfileCode;
        Profile.Description := Description;
        Profile.Kind := Kind;
        Profile."Keep First" := KeepFirst;
        Profile."Keep Last" := KeepLast;
        Profile.Insert();
    end;

    // ---- classification maps ---------------------------------------------------------------------

    // A classification the map does not know (a platform option added after this build) maps to
    // ToBeClassified, whose built-in verdict is Hidden: the caller fails CLOSED without having to
    // special-case it. An administrator who opens ToBeClassified opens such fields with it — the same
    // judgement call as for genuinely unclassified fields, which is what an unknown value is to Wicket.
    procedure DataClassOf(FieldRec: Record Field): Enum "Bcmag Data Class"
    var
        DataClass: Enum "Bcmag Data Class";
    begin
        if MapDataClass(FieldRec, DataClass) then
            exit(DataClass);
        exit(DataClass::ToBeClassified);
    end;

    // The invariant wire name of a classification (describe dataClassification, capabilities).
    procedure ClassName(DataClass: Enum "Bcmag Data Class"): Text
    begin
        case DataClass of
            DataClass::CustomerContent:
                exit('CustomerContent');
            DataClass::ToBeClassified:
                exit('ToBeClassified');
            DataClass::EndUserIdentifiableInformation:
                exit('EndUserIdentifiableInformation');
            DataClass::AccountData:
                exit('AccountData');
            DataClass::EndUserPseudonymousIdentifiers:
                exit('EndUserPseudonymousIdentifiers');
            DataClass::OrganizationIdentifiableInformation:
                exit('OrganizationIdentifiableInformation');
            DataClass::SystemMetadata:
                exit('SystemMetadata');
        end;
        exit('Unknown');
    end;

    // Describe reports a field's own classification, so an unknown value is reported as 'Unknown'
    // (truthfully) rather than as the ToBeClassified it is POLICED as.
    procedure DataClassNameOf(FieldRec: Record Field): Text
    var
        DataClass: Enum "Bcmag Data Class";
    begin
        if MapDataClass(FieldRec, DataClass) then
            exit(ClassName(DataClass));
        exit('Unknown');
    end;

    local procedure MapDataClass(FieldRec: Record Field; var DataClass: Enum "Bcmag Data Class"): Boolean
    begin
        case FieldRec.DataClassification of
            FieldRec.DataClassification::CustomerContent:
                DataClass := DataClass::CustomerContent;
            FieldRec.DataClassification::ToBeClassified:
                DataClass := DataClass::ToBeClassified;
            FieldRec.DataClassification::EndUserIdentifiableInformation:
                DataClass := DataClass::EndUserIdentifiableInformation;
            FieldRec.DataClassification::AccountData:
                DataClass := DataClass::AccountData;
            FieldRec.DataClassification::EndUserPseudonymousIdentifiers:
                DataClass := DataClass::EndUserPseudonymousIdentifiers;
            FieldRec.DataClassification::OrganizationIdentifiableInformation:
                DataClass := DataClass::OrganizationIdentifiableInformation;
            FieldRec.DataClassification::SystemMetadata:
                DataClass := DataClass::SystemMetadata;
            else
                exit(false);
        end;
        exit(true);
    end;

    // The verdict a classification resolves to in ByClassification mode before any per-field row or
    // per-user exception: the rule row if one exists, else the built-in default.
    procedure ClassificationRule(DataClass: Enum "Bcmag Data Class"; var Access: Enum "Bcmag Read Access"; var ProfileCode: Code[20])
    var
        Rule: Record "Bcmag Classification Rule";
    begin
        if Rule.Get(DataClass) then begin
            Access := Rule."Read Access";
            ProfileCode := Rule."Mask Profile";
            exit;
        end;
        BuiltInRule(DataClass, Access, ProfileCode);
    end;
}
