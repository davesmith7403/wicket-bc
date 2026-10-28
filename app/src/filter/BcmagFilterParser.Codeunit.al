codeunit 94109 "Bcmag Filter Parser"
{
    // Recursive-descent parser: tokens -> JSON AST. AST nodes are carried as JsonToken
    // (JsonValue is a leaf type and cannot hold an object), so each node is built as a
    // JsonObject and surfaced via .AsToken().

    procedure Parse(Tokens: JsonArray; var Ast: JsonObject; var ErrorMsg: Text): Boolean
    var
        Pos: Integer;
        Result: JsonToken;
    begin
        Pos := 0;
        if not ParseOr(Tokens, Pos, Result, ErrorMsg) then exit(false);
        if Pos < Tokens.Count() then begin
            ErrorMsg := StrSubstNo('extra tokens after expression at index %1', Pos);
            exit(false);
        end;
        Ast := Result.AsObject();
        exit(true);
    end;

    local procedure ParseOr(Tokens: JsonArray; var Pos: Integer; var Result: JsonToken; var ErrorMsg: Text): Boolean
    var
        Left, Right: JsonToken;
        Node: JsonObject;
    begin
        if not ParseAnd(Tokens, Pos, Left, ErrorMsg) then exit(false);
        while PeekKind(Tokens, Pos) = 'or' do begin
            Pos += 1;
            if not ParseAnd(Tokens, Pos, Right, ErrorMsg) then exit(false);
            Clear(Node);
            Node.Add('node', 'logical');
            Node.Add('op', 'or');
            Node.Add('left', Left);
            Node.Add('right', Right);
            Left := Node.AsToken();
        end;
        Result := Left;
        exit(true);
    end;

    local procedure ParseAnd(Tokens: JsonArray; var Pos: Integer; var Result: JsonToken; var ErrorMsg: Text): Boolean
    var
        Left, Right: JsonToken;
        Node: JsonObject;
    begin
        if not ParseNot(Tokens, Pos, Left, ErrorMsg) then exit(false);
        while PeekKind(Tokens, Pos) = 'and' do begin
            Pos += 1;
            if not ParseNot(Tokens, Pos, Right, ErrorMsg) then exit(false);
            Clear(Node);
            Node.Add('node', 'logical');
            Node.Add('op', 'and');
            Node.Add('left', Left);
            Node.Add('right', Right);
            Left := Node.AsToken();
        end;
        Result := Left;
        exit(true);
    end;

    local procedure ParseNot(Tokens: JsonArray; var Pos: Integer; var Result: JsonToken; var ErrorMsg: Text): Boolean
    var
        Inner: JsonToken;
        Node: JsonObject;
    begin
        if PeekKind(Tokens, Pos) = 'not' then begin
            Pos += 1;
            if not ParsePrimary(Tokens, Pos, Inner, ErrorMsg) then exit(false);
            Clear(Node);
            Node.Add('node', 'not');
            Node.Add('child', Inner);
            Result := Node.AsToken();
            exit(true);
        end;
        exit(ParsePrimary(Tokens, Pos, Result, ErrorMsg));
    end;

    local procedure ParsePrimary(Tokens: JsonArray; var Pos: Integer; var Result: JsonToken; var ErrorMsg: Text): Boolean
    var
        Kind: Text;
    begin
        if PeekKind(Tokens, Pos) = 'lparen' then begin
            Pos += 1;
            if not ParseOr(Tokens, Pos, Result, ErrorMsg) then exit(false);
            if PeekKind(Tokens, Pos) <> 'rparen' then begin
                ErrorMsg := 'expected )';
                exit(false);
            end;
            Pos += 1;
            exit(true);
        end;

        Kind := PeekKind(Tokens, Pos);
        case Kind of
            'fn_startswith', 'fn_endswith', 'fn_contains':
                exit(ParseFunc(Tokens, Pos, Result, ErrorMsg));
            'ident', 'fieldNo':
                exit(ParseFieldExpr(Tokens, Pos, Result, ErrorMsg));
        end;
        ErrorMsg := StrSubstNo('unexpected token %1 (%2)', PeekKind(Tokens, Pos), PeekValue(Tokens, Pos));
        exit(false);
    end;

    local procedure ParseFieldExpr(Tokens: JsonArray; var Pos: Integer; var Result: JsonToken; var ErrorMsg: Text): Boolean
    var
        Field: JsonObject;
        Op, Kind: Text;
        Lit: JsonToken;
        Node: JsonObject;
        Values: JsonArray;
    begin
        Clear(Field);
        Field.Add('kind', PeekKind(Tokens, Pos));
        Field.Add('value', PeekValue(Tokens, Pos));
        Pos += 1;

        Kind := PeekKind(Tokens, Pos);
        if Kind = 'in' then begin
            Pos += 1;
            if PeekKind(Tokens, Pos) <> 'lparen' then begin
                ErrorMsg := 'expected ( after in';
                exit(false);
            end;
            Pos += 1;
            Clear(Values);
            // Strict list grammar: literal (',' literal)* ')'. A missing comma ('a' 'b') or a
            // trailing one ('a',) is a malformed request, not something to guess the meaning of.
            // null is refused here: a membership test against "no value" is spelled "eq null".
            if PeekKind(Tokens, Pos) <> 'rparen' then
                repeat
                    if PeekKind(Tokens, Pos) = 'null' then begin
                        ErrorMsg := 'null is not allowed inside in (...); use "F eq null" for an empty-value test';
                        exit(false);
                    end;
                    if not ParseLiteral(Tokens, Pos, Lit, ErrorMsg) then exit(false);
                    Values.Add(Lit);
                    case PeekKind(Tokens, Pos) of
                        'comma':
                            begin
                                Pos += 1;
                                if PeekKind(Tokens, Pos) = 'rparen' then begin
                                    ErrorMsg := 'trailing comma in in (...); remove it or add a value';
                                    exit(false);
                                end;
                            end;
                        'rparen':
                            ;
                        else begin
                            ErrorMsg := StrSubstNo('expected , or ) in in (...), got %1', PeekKind(Tokens, Pos));
                            exit(false);
                        end;
                    end;
                until PeekKind(Tokens, Pos) = 'rparen';
            Pos += 1;
            Clear(Node);
            Node.Add('node', 'in');
            Node.Add('field', Field);
            Node.Add('values', Values);
            Result := Node.AsToken();
            exit(true);
        end;

        Op := MapOp(Kind);
        if Op = '' then begin
            ErrorMsg := StrSubstNo('expected comparison operator, got %1', Kind);
            exit(false);
        end;
        Pos += 1;
        if IsBoolIdent(Tokens, Pos) then
            ConsumeBoolLiteral(Tokens, Pos, Lit)
        else
            if not ParseLiteral(Tokens, Pos, Lit, ErrorMsg) then exit(false);
        Clear(Node);
        Node.Add('node', 'binop');
        Node.Add('op', Op);
        Node.Add('field', Field);
        Node.Add('value', Lit);
        Result := Node.AsToken();
        exit(true);
    end;

    local procedure ParseFunc(Tokens: JsonArray; var Pos: Integer; var Result: JsonToken; var ErrorMsg: Text): Boolean
    var
        Fn: Text;
        Field: JsonObject;
        Lit: JsonToken;
        Node: JsonObject;
    begin
        case PeekKind(Tokens, Pos) of
            'fn_startswith':
                Fn := 'startswith';
            'fn_endswith':
                Fn := 'endswith';
            'fn_contains':
                Fn := 'contains';
        end;
        Pos += 1;
        if PeekKind(Tokens, Pos) <> 'lparen' then begin
            ErrorMsg := 'expected (';
            exit(false);
        end;
        Pos += 1;
        if not (PeekKind(Tokens, Pos) in ['ident', 'fieldNo']) then begin
            ErrorMsg := 'expected field reference';
            exit(false);
        end;
        Clear(Field);
        Field.Add('kind', PeekKind(Tokens, Pos));
        Field.Add('value', PeekValue(Tokens, Pos));
        Pos += 1;
        if PeekKind(Tokens, Pos) <> 'comma' then begin
            ErrorMsg := 'expected ,';
            exit(false);
        end;
        Pos += 1;
        if not ParseLiteral(Tokens, Pos, Lit, ErrorMsg) then exit(false);
        if PeekKind(Tokens, Pos) <> 'rparen' then begin
            ErrorMsg := 'expected )';
            exit(false);
        end;
        Pos += 1;

        Clear(Node);
        Node.Add('node', 'func');
        Node.Add('fn', Fn);
        Node.Add('field', Field);
        Node.Add('value', Lit);
        Result := Node.AsToken();
        exit(true);
    end;

    local procedure ParseLiteral(Tokens: JsonArray; var Pos: Integer; var Lit: JsonToken; var ErrorMsg: Text): Boolean
    var
        LitObj: JsonObject;
    begin
        case PeekKind(Tokens, Pos) of
            'string', 'number', 'date', 'datetime', 'null':
                begin
                    Clear(LitObj);
                    LitObj.Add('kind', PeekKind(Tokens, Pos));
                    LitObj.Add('value', PeekValue(Tokens, Pos));
                    Pos += 1;
                    Lit := LitObj.AsToken();
                    exit(true);
                end;
        end;
        ErrorMsg := StrSubstNo('expected literal, got %1', PeekKind(Tokens, Pos));
        exit(false);
    end;

    // OData reserves true/false (case-insensitive) as boolean literals, so an ident spelled
    // that way in VALUE position is always a bool literal — a field literally named "true"
    // is possible in AL but deliberately not supported as a comparison value. Bool literals
    // are valid only as the right-hand side of a comparison, not in in-lists or functions.
    local procedure IsBoolIdent(Tokens: JsonArray; Pos: Integer): Boolean
    begin
        if PeekKind(Tokens, Pos) <> 'ident' then exit(false);
        exit(LowerCase(PeekValue(Tokens, Pos)) in ['true', 'false']);
    end;

    local procedure ConsumeBoolLiteral(Tokens: JsonArray; var Pos: Integer; var Lit: JsonToken)
    var
        LitObj: JsonObject;
    begin
        LitObj.Add('kind', 'bool');
        LitObj.Add('value', LowerCase(PeekValue(Tokens, Pos)));
        Pos += 1;
        Lit := LitObj.AsToken();
    end;

    local procedure MapOp(Kind: Text): Text
    begin
        case Kind of
            'op_eq':
                exit('eq');
            'op_ne':
                exit('ne');
            'op_gt':
                exit('gt');
            'op_ge':
                exit('ge');
            'op_lt':
                exit('lt');
            'op_le':
                exit('le');
        end;
        exit('');
    end;

    local procedure PeekKind(Tokens: JsonArray; Pos: Integer): Text
    var
        Tok: JsonToken;
        Inner: JsonToken;
    begin
        if Pos >= Tokens.Count() then exit('');
        Tokens.Get(Pos, Tok);
        Tok.AsObject().Get('kind', Inner);
        exit(Inner.AsValue().AsText());
    end;

    local procedure PeekValue(Tokens: JsonArray; Pos: Integer): Text
    var
        Tok: JsonToken;
        Inner: JsonToken;
    begin
        if Pos >= Tokens.Count() then exit('');
        Tokens.Get(Pos, Tok);
        Tok.AsObject().Get('value', Inner);
        exit(Inner.AsValue().AsText());
    end;
}
