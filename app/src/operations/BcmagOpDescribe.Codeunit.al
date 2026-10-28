codeunit 94112 "Bcmag Op Describe"
{
    var
        Setup: Record "Bcmag Setup";
        Problem: Codeunit "Bcmag Problem";
        Captions: Codeunit "Bcmag Caption Resolver";
        FieldPolicy: Codeunit "Bcmag Field Policy";
        PolicyDefaults: Codeunit "Bcmag Policy Defaults";
        Masker: Codeunit "Bcmag Field Masker";
        JsonRead: Codeunit "Bcmag Json Read";
        ApiCatalog: Codeunit "Bcmag Api Catalog";
        AppInfo: Codeunit "Bcmag App Info";
        SchemaVersionTok: Label '1.0', Locked = true;

    procedure Run(Data: JsonObject; var Response: JsonObject; var Fail: JsonObject; var Cost: Integer): Boolean
    var
        Tok: JsonToken;
        Kind: Text;
        TableId, CodeunitId: Integer;
        Suggest: JsonObject;
        Kinds: JsonArray;
    begin
        Cost := 1;
        Setup.GetSingleton();
        if not Data.Get('kind', Tok) then begin
            Fail := Problem.NewFailure(400, 'missing-field', 'Missing kind', 'data.kind is required ("table" | "codeunit" | "api")');
            exit(false);
        end;
        if not JsonRead.ReadText(Tok, 'kind', Kind, Fail) then exit(false);
        case Kind of
            'table':
                begin
                    if not Data.Get('tableId', Tok) then begin
                        Fail := Problem.NewFailure(400, 'missing-field', 'Missing tableId', 'data.tableId is required for kind="table"');
                        exit(false);
                    end;
                    if not JsonRead.ReadInteger(Tok, 'tableId', TableId, Fail) then exit(false);
                    exit(DescribeTable(TableId, Data, Response, Fail));
                end;
            'codeunit':
                begin
                    if not Data.Get('codeunitId', Tok) then begin
                        Fail := Problem.NewFailure(400, 'missing-field', 'Missing codeunitId', 'data.codeunitId is required for kind="codeunit"');
                        exit(false);
                    end;
                    if not JsonRead.ReadInteger(Tok, 'codeunitId', CodeunitId, Fail) then exit(false);
                    exit(DescribeCodeunit(CodeunitId, Data, Response, Fail));
                end;
            'api':
                exit(DescribeApi(Data, Response, Fail));
        end;
        Kinds.Add('table');
        Kinds.Add('codeunit');
        Kinds.Add('api');
        Suggest.Add('kinds', Kinds);
        Fail := Problem.NewFailureSuggest(400, 'unknown-kind', 'Unknown kind', StrSubstNo('unknown kind "%1"', Kind), Suggest);
        exit(false);
    end;

    local procedure DescribeTable(TableId: Integer; Data: JsonObject; var Response: JsonObject; var Fail: JsonObject): Boolean
    var
        Exposure: Record "Bcmag Exposure";
        AllObj: Record AllObjWithCaption;
        TableValue, NotModifiedValue, Include: JsonObject;
        FieldsArr, KeysArr, PrimaryKeyArr, ReferencedByArr: JsonArray;
        Permissions: JsonObject;
        Tok: JsonToken;
        RecRef: RecordRef;
        LangCodes: List of [Text];
        IfNoneMatch, Version: Text;
        WantReferencedBy, ReferencedByTruncated: Boolean;
    begin
        if not Exposure.IsAllowed(Exposure."Object Type"::Table, TableId, 'read') then begin
            Fail := Problem.NewFailure(403, 'not-exposed', 'Table not exposed', StrSubstNo('table %1 is not exposed', TableId));
            exit(false);
        end;
        if not AllObj.Get(AllObj."Object Type"::Table, TableId) then begin
            Fail := Problem.NewFailure(404, 'unknown-table', 'Unknown table', StrSubstNo('table %1 does not exist', TableId));
            exit(false);
        end;

        if not Captions.ReadLanguages(Data, Setup."Default Languages", LangCodes, Fail) then exit(false);
        if Data.Get('ifNoneMatch', Tok) then
            if not JsonRead.ReadText(Tok, 'ifNoneMatch', IfNoneMatch, Fail) then exit(false);
        if Data.Get('include', Tok) then begin
            if not Tok.IsObject() then begin
                Fail := Problem.NewFailure(400, 'invalid-field', 'Invalid include', 'data.include must be an object, e.g. { "referencedBy": true }');
                exit(false);
            end;
            Include := Tok.AsObject();
            if Include.Get('referencedBy', Tok) then
                if not JsonRead.ReadBoolean(Tok, 'include.referencedBy', WantReferencedBy, Fail) then exit(false);
        end;
        // The masker caches mask profiles per instance and this handler can outlive a request: start
        // each describe from the profiles as they are now.
        Clear(Masker);

        TableValue.Add('tableId', TableId);
        TableValue.Add('name', AllObj."Object Name");
        TableValue.Add('captionML', Captions.ObjectCaptions(AllObj."Object Type"::Table, TableId, LangCodes));
        AppInfo.AddAppMember(TableValue, AllObj."App Package ID");
        TableValue.Add('schemaVersion', SchemaVersionTok);

        BuildPrimaryKey(TableId, PrimaryKeyArr);
        TableValue.Add('primaryKey', PrimaryKeyArr);
        BuildFields(TableId, LangCodes, FieldsArr);
        TableValue.Add('fields', FieldsArr);
        BuildKeys(TableId, KeysArr);
        TableValue.Add('keys', KeysArr);
        TableValue.Add('hasSystemFields', HasSystemFields(TableId));
        // The tenant's API pages over this table, so an agent can weigh reading through one of them
        // (describe kind "api" answers whether it may) against the dynamic plane.
        TableValue.Add('apiRoutes', ApiCatalog.RoutesForTable(TableId));

        RecRef.Open(TableId);
        // Per spec §16 R8: read derives from ReadPermission, the write ops from
        // WritePermission. These are necessary-but-not-sufficient; the real check is at action time.
        Permissions.Add('read', RecRef.ReadPermission());
        Permissions.Add('insert', RecRef.WritePermission());
        Permissions.Add('modify', RecRef.WritePermission());
        Permissions.Add('delete', RecRef.WritePermission());
        RecRef.Close();
        TableValue.Add('permissions', Permissions);
        if WantReferencedBy then begin
            BuildReferencedBy(TableId, ReferencedByArr, ReferencedByTruncated);
            TableValue.Add('referencedBy', ReferencedByArr);
            if ReferencedByTruncated then
                TableValue.Add('referencedByTruncated', true);
        end;

        // The answer's own hash: it moves with anything this caller would see differently — structure,
        // field policy, masking, exceptions, the unmask tier, BC permissions — so a client may cache the
        // answer and revalidate it with ifNoneMatch without ever serving a stale policy view.
        Version := HashOf(TableValue);
        Clear(Response);
        if (IfNoneMatch <> '') and (IfNoneMatch = Version) then begin
            NotModifiedValue.Add('tableId', TableId);
            NotModifiedValue.Add('describeVersion', Version);
            NotModifiedValue.Add('notModified', true);
            Response.Add('value', NotModifiedValue);
            exit(true);
        end;
        TableValue.Add('describeVersion', Version);
        Response.Add('value', TableValue);
        exit(true);
    end;

    local procedure HashOf(Value: JsonObject): Text
    var
        CryptographyMgt: Codeunit "Cryptography Management";
        HashAlgorithm: Option MD5,SHA1,SHA256,SHA384,SHA512;
        Serialized: Text;
    begin
        Value.WriteTo(Serialized);
        exit(LowerCase(CryptographyMgt.GenerateHash(Serialized, HashAlgorithm::SHA256)));
    end;

    // The fields of OTHER tables (and self-references) whose TableRelation targets this table — how a
    // solution table hanging off Customer is found. Only tables the caller may read (exposure and BC
    // read permission) and fields the field policy does not hide are listed, so a hidden field's name
    // never appears. It scans the Field metadata of every table, hence opt-in and capped.
    local procedure BuildReferencedBy(TableId: Integer; var ReferencedByArr: JsonArray; var Truncated: Boolean)
    var
        FieldRec: Record Field;
        Exposure: Record "Bcmag Exposure";
        Entry: JsonObject;
        LastTableNo: Integer;
        TableReadable: Boolean;
    begin
        LastTableNo := -1;
        FieldRec.SetRange(RelationTableNo, TableId);
        FieldRec.SetRange(Class, FieldRec.Class::Normal);
        FieldRec.SetFilter(ObsoleteState, '<>%1', FieldRec.ObsoleteState::Removed);
        if FieldRec.FindSet() then
            repeat
                if FieldRec.TableNo <> LastTableNo then begin
                    LastTableNo := FieldRec.TableNo;
                    TableReadable := Exposure.IsAllowed(Exposure."Object Type"::Table, FieldRec.TableNo, 'read') and CanReadTable(FieldRec.TableNo);
                end;
                if TableReadable then
                    if FieldPolicy.IsReadable(FieldRec.TableNo, FieldRec."No.") then begin
                        if ReferencedByArr.Count() >= MaxReferencedBy() then begin
                            Truncated := true;
                            exit;
                        end;
                        Clear(Entry);
                        Entry.Add('tableId', FieldRec.TableNo);
                        Entry.Add('tableName', FieldRec.TableName);
                        Entry.Add('fieldNo', FieldRec."No.");
                        Entry.Add('fieldName', FieldRec.FieldName);
                        ReferencedByArr.Add(Entry);
                    end;
            until FieldRec.Next() = 0;
    end;

    local procedure CanReadTable(TableNo: Integer): Boolean
    var
        RecRef: RecordRef;
        Readable: Boolean;
    begin
        if not TryOpen(RecRef, TableNo) then
            exit(false);
        Readable := RecRef.ReadPermission();
        RecRef.Close();
        exit(Readable);
    end;

    [TryFunction]
    local procedure TryOpen(var RecRef: RecordRef; TableNo: Integer)
    begin
        RecRef.Open(TableNo);
    end;

    local procedure MaxReferencedBy(): Integer
    begin
        exit(200);
    end;

    // One API page (pageId) or API query (queryId): its routes, operations, and each API field mapped
    // to the table field it is bound to, with readable/routable answered under the CURRENT exposure,
    // field policy and API Routing switch. Unlike describe kind "table" it does not refuse a table the
    // caller may not read: the API's shape is already public in $metadata, and routable=false (with
    // notRoutableReason) is exactly the answer a client needs before choosing the dynamic plane.
    local procedure DescribeApi(Data: JsonObject; var Response: JsonObject; var Fail: JsonObject): Boolean
    var
        Tok: JsonToken;
        ApiValue: JsonObject;
        PageId, QueryId: Integer;
        Found: Boolean;
    begin
        if Data.Get('pageId', Tok) then begin
            if not JsonRead.ReadInteger(Tok, 'pageId', PageId, Fail) then exit(false);
            Found := ApiCatalog.DescribeApi(PageId, ApiValue);
        end else
            if Data.Get('queryId', Tok) then begin
                if not JsonRead.ReadInteger(Tok, 'queryId', QueryId, Fail) then exit(false);
                Found := ApiCatalog.DescribeApiQuery(QueryId, ApiValue);
            end else begin
                Fail := Problem.NewFailure(400, 'missing-field', 'Missing pageId', 'data.pageId (an API page) or data.queryId (an API query) is required for kind="api"; find them with discover kind="apis"');
                exit(false);
            end;
        if not Found then begin
            if PageId <> 0 then
                Fail := Problem.NewFailure(404, 'unknown-api', 'Unknown API', StrSubstNo('page %1 is not an API page', PageId))
            else
                Fail := Problem.NewFailure(404, 'unknown-api', 'Unknown API', StrSubstNo('query %1 is not an API query', QueryId));
            exit(false);
        end;
        ApiValue.Add('catalogVersion', ApiCatalog.CatalogVersion());
        ApiValue.Add('schemaVersion', SchemaVersionTok);
        Clear(Response);
        Response.Add('value', ApiValue);
        exit(true);
    end;

    local procedure DescribeCodeunit(CodeunitId: Integer; Data: JsonObject; var Response: JsonObject; var Fail: JsonObject): Boolean
    var
        Exposure: Record "Bcmag Exposure";
        AllObj: Record AllObjWithCaption;
        Catalog: Record "Bcmag Procedure Catalog";
        CodeunitValue: JsonObject;
        ProceduresArr: JsonArray;
        ProcObj, ArgsSchema: JsonObject;
        SchemaText: Text;
    begin
        // invoke is always deny-by-default: only enrolled procedures are ever revealed.
        if not Exposure.IsAllowed(Exposure."Object Type"::Codeunit, CodeunitId, 'invoke') then begin
            Fail := Problem.NewFailure(403, 'not-exposed', 'Codeunit not exposed', StrSubstNo('codeunit %1 is not exposed for invoke', CodeunitId));
            exit(false);
        end;
        if not AllObj.Get(AllObj."Object Type"::Codeunit, CodeunitId) then begin
            Fail := Problem.NewFailure(404, 'unknown-codeunit', 'Unknown codeunit', StrSubstNo('codeunit %1 does not exist', CodeunitId));
            exit(false);
        end;

        CodeunitValue.Add('codeunitId', CodeunitId);
        CodeunitValue.Add('name', AllObj."Object Name");
        CodeunitValue.Add('schemaVersion', SchemaVersionTok);

        Catalog.SetRange("Logical Codeunit Id", CodeunitId);
        Catalog.SetRange("Allow Run", true);
        if Catalog.FindSet() then
            repeat
                Clear(ProcObj);
                ProcObj.Add('procedure', Catalog."Procedure Name");
                ProcObj.Add('returnShape', Catalog."Return Shape".Names().Get(Catalog."Return Shape".Ordinals().IndexOf(Catalog."Return Shape".AsInteger())));
                Clear(ArgsSchema);
                SchemaText := Catalog.GetArgsSchema();
                if SchemaText <> '' then
                    if ArgsSchema.ReadFrom(SchemaText) then
                        ProcObj.Add('argsSchema', ArgsSchema);
                if Catalog.Description <> '' then
                    ProcObj.Add('description', Catalog.Description);
                ProceduresArr.Add(ProcObj);
            until Catalog.Next() = 0;
        CodeunitValue.Add('procedures', ProceduresArr);

        Clear(Response);
        Response.Add('value', CodeunitValue);
        exit(true);
    end;

    local procedure BuildFields(TableId: Integer; LangCodes: List of [Text]; var FieldsArr: JsonArray)
    var
        FieldRec: Record Field;
        FieldObj, RelObj: JsonObject;
        RelArr: JsonArray;
        PrimaryKeyFields: List of [Integer];
        RecRef: RecordRef;
        Readable, Masked: Boolean;
        ProfileCode: Code[20];
        TypeName: Text;
        MaskedFieldType: FieldType;
    begin
        GetPrimaryKeyFields(TableId, PrimaryKeyFields);
        RecRef.Open(TableId);
        FieldRec.SetRange(TableNo, TableId);
        // Normal + FlowField only — FlowFilter holds a filter, not a value.
        FieldRec.SetFilter(Class, '%1|%2', FieldRec.Class::Normal, FieldRec.Class::FlowField);
        // A removed option/enum field survives in the Field metadata but RecRef.Field(No) throws
        // for it, which would turn optionMembers resolution into a 500 for the whole table.
        FieldRec.SetFilter(ObsoleteState, '<>%1', FieldRec.ObsoleteState::Removed);
        if FieldRec.FindSet() then
            repeat
                // A field the caller may not read is omitted entirely — its metadata (name,
                // relations, classification) is already a leak — unless the admin opts in via
                // "Describe Restricted Fields", which advertises it with readable=false. PK
                // fields are always readable, so the addressing fields always appear.
                Readable := FieldPolicy.IsReadable(TableId, FieldRec."No.");
                if Readable or Setup."Describe Restricted Fields" then begin
                    // A readable field is Clear or Masked. A Masked one is emitted as its mask rendering,
                    // so its wire type is the rendering's (Hash/Fixed turn a non-text field into a string).
                    Masked := false;
                    TypeName := FieldOptionName(FieldRec, FieldRec.FieldNo(Type));
                    if Readable then
                        Masked := FieldPolicy.ReadVerdict(TableId, FieldRec."No.", ProfileCode) = "Bcmag Read Access"::Masked;
                    MaskedFieldType := FieldType::Text;
                    if Masked then
                        if RecRef.FieldExist(FieldRec."No.") then begin
                            MaskedFieldType := RecRef.Field(FieldRec."No.").Type;
                            TypeName := Masker.EmittedTypeName(MaskedFieldType, ProfileCode, TypeName);
                        end;
                    Clear(FieldObj);
                    FieldObj.Add('no', FieldRec."No.");
                    FieldObj.Add('name', FieldRec.FieldName);
                    FieldObj.Add('type', TypeName);
                    FieldObj.Add('length', FieldRec.Len);
                    FieldObj.Add('class', FieldOptionName(FieldRec, FieldRec.FieldNo(Class)));
                    FieldObj.Add('dataClassification', PolicyDefaults.DataClassNameOf(FieldRec));
                    FieldObj.Add('captionML', Captions.FieldCaption(TableId, FieldRec."No.", LangCodes));
                    FieldObj.Add('nullable', not PrimaryKeyFields.Contains(FieldRec."No."));
                    FieldObj.Add('readable', Readable);
                    FieldObj.Add('writable', FieldPolicy.IsWritable(TableId, FieldRec."No."));
                    // access says HOW a readable field reads. A restricted field advertised under
                    // "Describe Restricted Fields" keeps its v1.1 shape (readable=false, no access).
                    // A masked field cannot be filtered, sorted or aggregated on — row membership or
                    // order would reveal the value the mask hides — so it says so up front.
                    if Readable then
                        if Masked then begin
                            FieldObj.Add('access', 'masked');
                            FieldObj.Add('mask', MaskObject(ProfileCode, MaskedFieldType));
                            FieldObj.Add('filterable', false);
                            FieldObj.Add('sortable', false);
                        end else
                            FieldObj.Add('access', 'clear');
                    if (FieldRec.Type = FieldRec.Type::Option) and RecRef.FieldExist(FieldRec."No.") then
                        FieldObj.Add('optionMembers', Captions.OptionMemberCaptions(RecRef.Field(FieldRec."No."), LangCodes));
                    if FieldRec.Type in [FieldRec.Type::BLOB, FieldRec.Type::Media, FieldRec.Type::MediaSet] then
                        FieldObj.Add('binary', true);
                    if FieldRec.RelationTableNo <> 0 then begin
                        Clear(RelArr);
                        Clear(RelObj);
                        RelObj.Add('tableId', FieldRec.RelationTableNo);
                        if FieldRec.RelationFieldNo <> 0 then
                            RelObj.Add('fieldNo', FieldRec.RelationFieldNo);
                        RelArr.Add(RelObj);
                        FieldObj.Add('tableRelation', RelArr);
                    end;
                    FieldsArr.Add(FieldObj);
                end;
            until FieldRec.Next() = 0;
        RecRef.Close();
    end;

    // { profile, kind }: the profile code ('' = the built-in partial mask) and the invariant name of the
    // kind the field actually renders with (Hash on a Boolean/Option field renders null).
    local procedure MaskObject(ProfileCode: Code[20]; FieldType: FieldType) MaskObj: JsonObject
    begin
        MaskObj.Add('profile', ProfileCode);
        MaskObj.Add('kind', Masker.EffectiveKindName(FieldType, ProfileCode));
    end;

    // Invariant member name of one of the Field record's own option columns (Type, Class). Format()
    // would give the caption in the session language, so an agent keying on type = "Decimal"
    // would break on a non-English session; the enum metadata name is the stable identifier.
    local procedure FieldOptionName(FieldRec: Record Field; OptionFieldNo: Integer): Text
    var
        RecRef: RecordRef;
        OptionRef: FieldRef;
        Ordinal: Integer;
    begin
        RecRef.GetTable(FieldRec);
        OptionRef := RecRef.Field(OptionFieldNo);
        Ordinal := OptionRef.Value;
        exit(OptionRef.GetEnumValueNameFromOrdinalValue(Ordinal));
    end;

    local procedure BuildKeys(TableId: Integer; var KeysArr: JsonArray)
    var
        KeyRec: Record "Key";
        KeyObj: JsonObject;
        FieldsArr: JsonArray;
        Parts: List of [Text];
        Part: Text;
        FieldRec: Record Field;
        KeyFieldNos: List of [Integer];
        FieldNo: Integer;
        RestrictedField: Boolean;
    begin
        KeyRec.SetRange(TableNo, TableId);
        if KeyRec.FindSet() then
            repeat
                Clear(KeyObj);
                Clear(FieldsArr);
                Clear(Parts);
                Clear(KeyFieldNos);
                RestrictedField := false;
                Parts := KeyRec."Key".Split(',');
                foreach Part in Parts do begin
                    FieldRec.SetRange(TableNo, TableId);
                    FieldRec.SetRange(FieldName, DelChr(Part, '<>', ' '));
                    if FieldRec.FindFirst() then begin
                        KeyFieldNos.Add(FieldRec."No.");
                        if not FieldPolicy.IsReadable(TableId, FieldRec."No.") then
                            RestrictedField := true;
                    end;
                end;
                // A key over a restricted field would leak that field's name (via the key string)
                // and its existence (via the index) — the same disclosure the fields[] loop
                // suppresses. Omit such a key unless the admin opts in via Describe Restricted
                // Fields. The primary key's fields are always readable, so addressing is unaffected.
                if (not RestrictedField) or Setup."Describe Restricted Fields" then begin
                    foreach FieldNo in KeyFieldNos do
                        FieldsArr.Add(FieldNo);
                    KeyObj.Add('name', KeyRec."Key");
                    KeyObj.Add('fields', FieldsArr);
                    KeyObj.Add('isPrimary', KeyRec."No." = 1);
                    KeyObj.Add('clustered', KeyRec.Clustered);
                    KeysArr.Add(KeyObj);
                end;
            until KeyRec.Next() = 0;
    end;

    local procedure BuildPrimaryKey(TableId: Integer; var PrimaryKeyArr: JsonArray)
    var
        FieldNos: List of [Integer];
        FieldNo: Integer;
    begin
        GetPrimaryKeyFields(TableId, FieldNos);
        foreach FieldNo in FieldNos do
            PrimaryKeyArr.Add(FieldNo);
    end;

    local procedure GetPrimaryKeyFields(TableId: Integer; var FieldNos: List of [Integer])
    var
        KeyRec: Record "Key";
        FieldRec: Record Field;
        Parts: List of [Text];
        Part: Text;
    begin
        KeyRec.SetRange(TableNo, TableId);
        KeyRec.SetRange("No.", 1);
        if not KeyRec.FindFirst() then exit;
        Parts := KeyRec."Key".Split(',');
        foreach Part in Parts do begin
            FieldRec.SetRange(TableNo, TableId);
            FieldRec.SetRange(FieldName, DelChr(Part, '<>', ' '));
            if FieldRec.FindFirst() then
                FieldNos.Add(FieldRec."No.");
        end;
    end;

    local procedure HasSystemFields(TableId: Integer): Boolean
    var
        FieldRec: Record Field;
    begin
        exit(FieldRec.Get(TableId, 2000000003)); // SystemModifiedAt
    end;
}
