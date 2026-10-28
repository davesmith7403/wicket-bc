codeunit 94111 "Bcmag Op Discover"
{
    var
        Setup: Record "Bcmag Setup";
        Exposure: Record "Bcmag Exposure";
        Problem: Codeunit "Bcmag Problem";
        Captions: Codeunit "Bcmag Caption Resolver";
        JsonRead: Codeunit "Bcmag Json Read";
        AppInfo: Codeunit "Bcmag App Info";

    // discover.filter is an AL filter string applied to "Object Caption" (or company Name).
    // Unlike query.filter it is NOT the OData $filter subset.
    procedure Run(Data: JsonObject; var Response: JsonObject; var Fail: JsonObject; var Cost: Integer): Boolean
    var
        AllObj: Record AllObjWithCaption;
        Tok: JsonToken;
        Kind, FilterText, PublisherFilter: Text;
        Top: Integer;
        Value: JsonArray;
        Suggest: JsonObject;
        Kinds: JsonArray;
        LangCodes: List of [Text];
    begin
        Setup.GetSingleton();
        if not Data.Get('kind', Tok) then begin
            Fail := Problem.NewFailure(400, 'missing-field', 'Missing kind', 'data.kind is required ("tables" | "codeunits" | "companies" | "apis")');
            exit(false);
        end;
        if not JsonRead.ReadText(Tok, 'kind', Kind, Fail) then exit(false);
        if Data.Get('filter', Tok) then
            if not JsonRead.ReadText(Tok, 'filter', FilterText, Fail) then exit(false);
        Top := Setup."Default Top";
        if Data.Get('top', Tok) then
            if not JsonRead.ReadInteger(Tok, 'top', Top, Fail) then exit(false);
        if Data.Get('publisher', Tok) then
            if not JsonRead.ReadText(Tok, 'publisher', PublisherFilter, Fail) then exit(false);
        if Top > Setup."Max Top" then Top := Setup."Max Top";
        if Top < 1 then Top := 1;

        if not Captions.ReadLanguages(Data, Setup."Default Languages", LangCodes, Fail) then exit(false);

        case Kind of
            'tables':
                if not DiscoverObjects(AllObj."Object Type"::Table, FilterText, PublisherFilter, Top, LangCodes, Value, Fail) then exit(false);
            'codeunits':
                if not DiscoverObjects(AllObj."Object Type"::Codeunit, FilterText, PublisherFilter, Top, LangCodes, Value, Fail) then exit(false);
            'companies':
                if not DiscoverCompanies(FilterText, Top, Value, Fail) then exit(false);
            'apis':
                exit(DiscoverApis(Data, FilterText, Top, Response, Fail, Cost));
            else begin
                Kinds.Add('tables');
                Kinds.Add('codeunits');
                Kinds.Add('companies');
                Kinds.Add('apis');
                Suggest.Add('kinds', Kinds);
                Fail := Problem.NewFailureSuggest(400, 'unknown-kind', 'Unknown kind',
                    StrSubstNo('unknown kind "%1"; expected tables, codeunits, companies, or apis', Kind), Suggest);
                exit(false);
            end;
        end;

        Cost := Value.Count();
        Clear(Response);
        Response.Add('value', Value);
        exit(true);
    end;

    // publisher is an AL filter on the owning app's Publisher ("<>Microsoft" finds solution objects);
    // objects that belong to no installed app (platform tables) never match it.
    local procedure DiscoverObjects(ObjectType: Option; FilterText: Text; PublisherFilter: Text; Top: Integer; LangCodes: List of [Text]; var Value: JsonArray; var Fail: JsonObject): Boolean
    var
        AllObj: Record AllObjWithCaption;
        Row, Permissions: JsonObject;
        PublisherPackages: List of [Text];
        InvalidPublisherFilterErr: Label '"%1" is not a valid filter on the app publisher: %2', Comment = '%1 = the filter, %2 = the platform error';
        Count: Integer;
        ExposureType: Option Table,Codeunit;
        IsTable: Boolean;
    begin
        if PublisherFilter <> '' then
            if not AppInfo.TryPackagesByPublisher(PublisherFilter, PublisherPackages) then begin
                Fail := Problem.NewFailure(400, 'invalid-filter', 'Invalid publisher filter',
                    StrSubstNo(InvalidPublisherFilterErr, PublisherFilter, GetLastErrorText()));
                exit(false);
            end;
        IsTable := ObjectType = AllObj."Object Type"::Table;
        if IsTable then ExposureType := ExposureType::Table else ExposureType := ExposureType::Codeunit;

        AllObj.SetRange("Object Type", ObjectType);
        // discover.filter is a raw AL filter on Object Caption; a malformed one would throw. Guard it
        // so the caller gets a 400 invalid-filter instead of an unguarded 500.
        if FilterText <> '' then
            if not TrySetCaptionFilter(AllObj, FilterText) then begin
                Fail := Problem.NewFailure(400, 'invalid-filter', 'Invalid discover filter',
                    StrSubstNo('"%1" is not a valid filter on Object Caption: %2', FilterText, GetLastErrorText()));
                exit(false);
            end;
        if AllObj.FindSet() then
            repeat
                if PublisherFilter <> '' then
                    if not PublisherPackages.Contains(AppInfo.PackageKey(AllObj."App Package ID")) then
                        continue;
                // Tables: deny-by-default unless Open; codeunits only if invoke-enrolled. IsAllowed
                // already answers Open mode itself AND applies the hard read denylist (audit/queue
                // tables) that holds in every mode — short-circuiting on Open here listed those
                // tables even though query/describe refuse them.
                if IsTable then begin
                    if not Exposure.IsAllowed(ExposureType, AllObj."Object ID", 'read') then
                        continue;
                    if not TableReadable(AllObj."Object ID", Permissions) then
                        continue;
                end else begin
                    if not Exposure.IsAllowed(ExposureType, AllObj."Object ID", 'invoke') then
                        continue;
                    Clear(Permissions);
                    Permissions.Add('invoke', true);
                end;

                Clear(Row);
                Row.Add('id', AllObj."Object ID");
                Row.Add('name', AllObj."Object Name");
                Row.Add('captionML', Captions.ObjectCaptions(ObjectType, AllObj."Object ID", LangCodes));
                if IsTable then Row.Add('scope', 'table') else Row.Add('scope', 'codeunit');
                AppInfo.AddAppMember(Row, AllObj."App Package ID");
                Row.Add('permissions', Permissions);
                Value.Add(Row);
                Count += 1;
                if Count >= Top then break;
            until AllObj.Next() = 0;
        exit(true);
    end;

    // The tenant's API pages and API queries (see Bcmag Api Catalog). Unlike tables, the catalog is not
    // filtered by the exposure allowlist: which APIs exist is already public in the tenant's $metadata,
    // and whether Wicket lets a client READ through one is answered per page by describe kind "api".
    // filter is an AL filter on the entity set name; tableId narrows to the API pages over one table.
    // ifNoneMatch carries a catalogVersion the caller cached: when it still matches, the rows are
    // omitted and notModified is true, so revalidating a cache costs one fingerprint and no listing.
    local procedure DiscoverApis(Data: JsonObject; FilterText: Text; Top: Integer; var Response: JsonObject; var Fail: JsonObject; var Cost: Integer): Boolean
    var
        Catalog: Codeunit "Bcmag Api Catalog";
        Tok: JsonToken;
        Value: JsonArray;
        Version, IfNoneMatch, BadFilter: Text;
        TableId, Skip, Total: Integer;
    begin
        if Data.Get('tableId', Tok) then
            if not JsonRead.ReadInteger(Tok, 'tableId', TableId, Fail) then exit(false);
        if Data.Get('skip', Tok) then
            if not JsonRead.ReadInteger(Tok, 'skip', Skip, Fail) then exit(false);
        if Skip < 0 then Skip := 0;
        if Data.Get('ifNoneMatch', Tok) then
            if not JsonRead.ReadText(Tok, 'ifNoneMatch', IfNoneMatch, Fail) then exit(false);

        Version := Catalog.CatalogVersion();
        Clear(Response);
        if (IfNoneMatch <> '') and (IfNoneMatch = Version) then begin
            Response.Add('value', Value);
            Response.Add('notModified', true);
            Response.Add('catalogVersion', Version);
            Response.Add('apiRouting', Catalog.RoutingModeName());
            Cost := 0;
            exit(true);
        end;

        if not Catalog.ListApis(FilterText, TableId, Skip, Top, Value, Total, BadFilter) then begin
            Fail := Problem.NewFailure(400, 'invalid-filter', 'Invalid discover filter',
                StrSubstNo('"%1" is not a valid filter on the API entity set name: %2', FilterText, BadFilter));
            exit(false);
        end;
        Response.Add('value', Value);
        Response.Add('catalogVersion', Version);
        Response.Add('apiRouting', Catalog.RoutingModeName());
        Response.Add('@count', Total);
        if Skip + Value.Count() < Total then
            Response.Add('@nextSkip', Skip + Value.Count());
        Cost := Value.Count();
        exit(true);
    end;

    [TryFunction]
    local procedure TrySetCaptionFilter(var AllObj: Record AllObjWithCaption; FilterText: Text)
    begin
        AllObj.SetFilter("Object Caption", FilterText);
    end;

    // Opens a RecordRef to test read permission (so Open mode never leaks schema for tables
    // the principal cannot read) and to compute the per-row permission flags.
    local procedure TableReadable(TableId: Integer; var Permissions: JsonObject): Boolean
    var
        RecRef: RecordRef;
    begin
        Clear(Permissions);
        if not TryOpen(RecRef, TableId) then
            exit(false);
        if not RecRef.ReadPermission() then begin
            RecRef.Close();
            exit(false);
        end;
        Permissions.Add('read', true);
        Permissions.Add('insert', RecRef.WritePermission());
        Permissions.Add('modify', RecRef.WritePermission());
        Permissions.Add('delete', RecRef.WritePermission());
        RecRef.Close();
        exit(true);
    end;

    [TryFunction]
    local procedure TryOpen(var RecRef: RecordRef; TableId: Integer)
    begin
        RecRef.Open(TableId);
    end;

    local procedure DiscoverCompanies(FilterText: Text; Top: Integer; var Value: JsonArray; var Fail: JsonObject): Boolean
    var
        Company: Record Company;
        Row, Captions2: JsonObject;
        Count: Integer;
    begin
        if FilterText <> '' then
            if not TrySetCompanyFilter(Company, FilterText) then begin
                Fail := Problem.NewFailure(400, 'invalid-filter', 'Invalid discover filter',
                    StrSubstNo('"%1" is not a valid filter on company Name: %2', FilterText, GetLastErrorText()));
                exit(false);
            end;
        if Company.FindSet() then
            repeat
                Clear(Row);
                Clear(Captions2);
                Row.Add('id', Company.Name);
                Row.Add('name', Company.Name);
                Captions2.Add('ENU', Company."Display Name");
                Row.Add('captionML', Captions2);
                Row.Add('scope', 'company');
                Value.Add(Row);
                Count += 1;
                if Count >= Top then break;
            until Company.Next() = 0;
        exit(true);
    end;

    [TryFunction]
    local procedure TrySetCompanyFilter(var Company: Record Company; FilterText: Text)
    begin
        Company.SetFilter(Name, FilterText);
    end;
}
