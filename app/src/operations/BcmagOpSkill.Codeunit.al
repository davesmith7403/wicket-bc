codeunit 94142 "Bcmag Op Skill"
{
    // "skill" operation: serve the protocol-education guide with progressive disclosure, so ANY client
    // (not just the MCP ones with repo access) can learn the envelope, transport, operations,
    // filter grammar, field policy, async, and actions. The content is fetched from a configured public
    // HTTPS URL (Setup "Skill Doc Url"), so the docs ship independently of the extension and can be
    // versioned per BC release. Read-only, no auth on the doc (host a public or SAS'd markdown).
    //
    // data: { mode?: "toc" | "section" | "full" (default "toc"), section?: text }
    //   toc     -> { title, description?, sections: [heading, ...] }   (cheap; call this first)
    //   section -> { section, content }   (one H2 section; case-insensitive/partial match on the name)
    //   full    -> { content }            (the whole document)

    Access = Public;

    var
        JsonRead: Codeunit "Bcmag Json Read";
        Problem: Codeunit "Bcmag Problem";
        Lf: Char;

    procedure Run(Data: JsonObject; var Response: JsonObject; var Fail: JsonObject; var Cost: Integer): Boolean
    var
        Setup: Record "Bcmag Setup";
        Value: JsonObject;
        Mode, Section, DocText: Text;
    begin
        Cost := 1;
        Lf := 10;
        Setup.GetSingleton();

        if Setup."Skill Doc Url" = '' then begin
            Fail := Problem.NewFailure(404, 'skill-not-configured', 'Skill not configured',
                'no skill document is configured (set Skill Doc Url on the Wicket Setup card)');
            exit(false);
        end;

        // Defense in depth: the table validates this on write, but the field may have been set
        // before that validation existed (or via code). Never fetch a non-HTTPS/internal URL.
        if not LowerCase(Setup."Skill Doc Url").StartsWith('https://') then begin
            Fail := Problem.NewFailure(502, 'skill-url-invalid', 'Skill URL invalid',
                'the configured Skill Doc Url does not start with https:// (fix it on the Wicket Setup card)');
            exit(false);
        end;

        Mode := LowerCase(GetTextOr(Data, 'mode', 'toc'));
        Section := GetTextOr(Data, 'section', '');

        if not FetchDoc(Setup."Skill Doc Url", DocText, Fail) then
            exit(false);

        case Mode of
            'toc':
                Value := BuildToc(DocText);
            'full':
                Value.Add('content', DocText);
            'section':
                begin
                    if Section = '' then begin
                        Fail := Problem.NewFailure(400, 'missing-field', 'Missing section',
                            'data.section is required when mode is "section"');
                        exit(false);
                    end;
                    if not BuildSection(DocText, Section, Value) then begin
                        Fail := Problem.NewFailureSuggest(404, 'unknown-section', 'Unknown section',
                            StrSubstNo('no section matching "%1"', Section), SectionList(DocText));
                        exit(false);
                    end;
                end;
            else begin
                Fail := Problem.NewFailure(400, 'invalid-mode', 'Invalid mode',
                    StrSubstNo('mode "%1" is not one of toc/section/full', Mode));
                exit(false);
            end;
        end;

        Clear(Response);
        Response.Add('value', Value);
        exit(true);
    end;

    [NonDebuggable]
    local procedure FetchDoc(Url: Text; var DocText: Text; var Fail: JsonObject): Boolean
    var
        Client: HttpClient;
        Response: HttpResponseMessage;
    begin
        if not Client.Get(Url, Response) then
            exit(FetchFailed('the GET request could not be sent', Fail));
        if not Response.IsSuccessStatusCode() then
            exit(FetchFailed(StrSubstNo('HTTP %1', Response.HttpStatusCode()), Fail));
        // Refuse oversized documents BEFORE reading when the server declares a length, and
        // re-check after ReadAs (Content-Length can be absent or lie under chunked encoding).
        // Cost is 1 and there is no caching, so an unbounded body is a memory-DoS surface.
        if ContentLengthExceeds(Response, MaxDocBytes()) then
            exit(TooLarge(Fail));
        Response.Content().ReadAs(DocText);
        if StrLen(DocText) > MaxDocBytes() then begin
            Clear(DocText);
            exit(TooLarge(Fail));
        end;
        if DocText = '' then
            exit(FetchFailed('the document was empty', Fail));
        exit(true);
    end;

    // 1 MB is generous for a markdown skill document while keeping SplitLines (which briefly
    // doubles the footprint into a List) bounded.
    local procedure MaxDocBytes(): Integer
    begin
        exit(1048576);
    end;

    local procedure ContentLengthExceeds(Response: HttpResponseMessage; MaxBytes: Integer): Boolean
    var
        ContentHeaders: HttpHeaders;
        Values: List of [Text];
        Declared: BigInteger;
    begin
        Response.Content().GetHeaders(ContentHeaders);
        if not ContentHeaders.Contains('Content-Length') then
            exit(false);
        if not ContentHeaders.GetValues('Content-Length', Values) then
            exit(false);
        if Values.Count() = 0 then
            exit(false);
        if not Evaluate(Declared, Values.Get(1)) then
            exit(false);
        exit(Declared > MaxBytes);
    end;

    local procedure FetchFailed(Detail: Text; var Fail: JsonObject): Boolean
    begin
        Fail := Problem.NewFailure(502, 'skill-fetch-failed', 'Skill fetch failed',
            StrSubstNo('could not fetch the skill document: %1', Detail));
        exit(false);
    end;

    local procedure TooLarge(var Fail: JsonObject): Boolean
    begin
        Fail := Problem.NewFailure(502, 'skill-too-large', 'Skill document too large',
            StrSubstNo('the skill document exceeds the %1-byte limit', MaxDocBytes()));
        exit(false);
    end;

    local procedure BuildToc(DocText: Text) Value: JsonObject
    var
        Sections: JsonArray;
        Lines: List of [Text];
        Line, Title, Description, Heading: Text;
    begin
        Lines := SplitLines(DocText);
        Title := FirstHeading(Lines, '# ');
        Description := Frontmatter(Lines, 'description:');
        foreach Line in Lines do
            if Line.StartsWith('## ') then begin
                Heading := CopyStr(Line, 4).Trim();
                Sections.Add(Heading);
            end;
        if Title <> '' then
            Value.Add('title', Title);
        if Description <> '' then
            Value.Add('description', Description);
        Value.Add('sections', Sections);
    end;

    local procedure BuildSection(DocText: Text; Wanted: Text; var Value: JsonObject): Boolean
    var
        Lines: List of [Text];
        Line, Heading, MatchedHeading: Text;
        Body: TextBuilder;
        Collecting: Boolean;
    begin
        Lines := SplitLines(DocText);
        foreach Line in Lines do begin
            if Line.StartsWith('## ') then begin
                if Collecting then
                    break; // reached the next section
                Heading := CopyStr(Line, 4).Trim();
                if HeadingMatches(Heading, Wanted) then begin
                    Collecting := true;
                    MatchedHeading := Heading;
                    Body.AppendLine(Line);
                end;
            end else
                if Collecting then
                    Body.AppendLine(Line);
        end;
        if not Collecting then
            exit(false);
        Value.Add('section', MatchedHeading);
        Value.Add('content', Body.ToText());
        exit(true);
    end;

    local procedure SectionList(DocText: Text) Suggest: JsonObject
    var
        Sections: JsonArray;
        Line: Text;
    begin
        foreach Line in SplitLines(DocText) do
            if Line.StartsWith('## ') then
                Sections.Add(CopyStr(Line, 4).Trim());
        Suggest.Add('sections', Sections);
    end;

    // Exact (case-insensitive) first, then substring, so "query" matches "### query — read records".
    local procedure HeadingMatches(Heading: Text; Wanted: Text): Boolean
    begin
        if LowerCase(Heading) = LowerCase(Wanted) then
            exit(true);
        exit(StrPos(LowerCase(Heading), LowerCase(Wanted)) > 0);
    end;

    local procedure FirstHeading(Lines: List of [Text]; Prefix: Text) Title: Text
    var
        Line: Text;
    begin
        foreach Line in Lines do
            if Line.StartsWith(Prefix) then
                exit(CopyStr(Line, StrLen(Prefix) + 1).Trim());
    end;

    // Best-effort single-line YAML frontmatter value (the block between the first two '---' lines).
    local procedure Frontmatter(Lines: List of [Text]; KeyName: Text) Value: Text
    var
        Line: Text;
        InFront: Boolean;
        Seen: Integer;
    begin
        foreach Line in Lines do begin
            if Line.Trim() = '---' then begin
                Seen += 1;
                InFront := Seen = 1;
                if Seen = 2 then
                    exit('');
                continue;
            end;
            if InFront and Line.StartsWith(KeyName) then
                exit(CopyStr(Line, StrLen(KeyName) + 1).Trim());
        end;
    end;

    local procedure SplitLines(DocText: Text) Lines: List of [Text]
    var
        Raw: Text;
    begin
        foreach Raw in DocText.Split(Format(Lf)) do
            Lines.Add(DelChr(Raw, '>', Format(13))); // strip a trailing CR
    end;

    local procedure GetTextOr(Data: JsonObject; Name: Text; Default: Text): Text
    var
        Tok: JsonToken;
    begin
        if Data.Get(Name, Tok) then
            if JsonRead.IsNonNullValue(Tok) then
                exit(Tok.AsValue().AsText());
        exit(Default);
    end;
}
