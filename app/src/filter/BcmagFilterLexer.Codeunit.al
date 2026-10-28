codeunit 94108 "Bcmag Filter Lexer"
{
    procedure Tokenize(Input: Text; var Tokens: JsonArray; var ErrorMsg: Text): Boolean
    var
        Pos: Integer;
        Ch: Char;
        Tok: JsonObject;
        Lit: Text;
    begin
        Clear(Tokens);
        Pos := 1;
        while Pos <= StrLen(Input) do begin
            Ch := Input[Pos];
            case true of
                Ch in [' ', 9, 10, 13]:
                    Pos += 1;
                Ch = '(':
                    begin AddTok(Tokens, 'lparen', '('); Pos += 1; end;
                Ch = ')':
                    begin AddTok(Tokens, 'rparen', ')'); Pos += 1; end;
                Ch = ',':
                    begin AddTok(Tokens, 'comma', ','); Pos += 1; end;
                Ch = '''':
                    if not ConsumeString(Input, Pos, Lit, ErrorMsg) then exit(false)
                    else AddTok(Tokens, 'string', Lit);
                Ch = '"':
                    if not ConsumeQuotedIdent(Input, Pos, Lit, ErrorMsg) then exit(false)
                    else AddTok(Tokens, 'ident', Lit);
                Ch = '#':
                    if not ConsumeFieldByNo(Input, Pos, Lit, ErrorMsg) then exit(false)
                    else AddTok(Tokens, 'fieldNo', Lit);
                (Ch in ['0' .. '9']) or ((Ch = '-') and IsNextDigit(Input, Pos)):
                    if not ConsumeNumberOrDate(Input, Pos, Lit, ErrorMsg) then exit(false)
                    else AddTok(Tokens, ResolveNumericKind(Lit), Lit);
                IsIdentStart(Ch):
                    begin
                        ConsumeBareIdent(Input, Pos, Lit);
                        AddTok(Tokens, ClassifyKeyword(Lit), Lit);
                    end;
                else begin
                    ErrorMsg := StrSubstNo('unexpected character %1 at position %2', Ch, Pos);
                    exit(false);
                end;
            end;
        end;
        exit(true);
    end;

    local procedure AddTok(var Tokens: JsonArray; Kind: Text; Value: Text)
    var
        Obj: JsonObject;
    begin
        Obj.Add('kind',  Kind);
        Obj.Add('value', Value);
        Tokens.Add(Obj);
    end;

    // OData string escaping: inside a literal a doubled '' is one apostrophe; a single '
    // closes it. The token value carries the UNESCAPED text — the applier re-escapes when
    // it wraps values as quoted AL filter literals.
    [TryFunction]
    local procedure ConsumeString(Input: Text; var Pos: Integer; var Lit: Text; var ErrorMsg: Text)
    var
        Builder: TextBuilder;
        Start: Integer;
        Closed: Boolean;
    begin
        Pos += 1;
        Start := Pos;
        while (Pos <= StrLen(Input)) and not Closed do
            if Input[Pos] <> '''' then
                Pos += 1
            else begin
                Builder.Append(CopyStr(Input, Start, Pos - Start));
                if (Pos < StrLen(Input)) and (Input[Pos + 1] = '''') then begin
                    Builder.Append('''');
                    Pos += 2;
                    Start := Pos;
                end else begin
                    Closed := true;
                    Pos += 1;
                end;
            end;
        if not Closed then begin
            ErrorMsg := 'unterminated string literal';
            Error('');
        end;
        Lit := Builder.ToText();
    end;

    [TryFunction]
    local procedure ConsumeQuotedIdent(Input: Text; var Pos: Integer; var Lit: Text; var ErrorMsg: Text)
    var
        Start: Integer;
    begin
        Pos += 1;
        Start := Pos;
        while (Pos <= StrLen(Input)) and (Input[Pos] <> '"') do Pos += 1;
        if Pos > StrLen(Input) then begin
            ErrorMsg := 'unterminated quoted identifier';
            Error('');
        end;
        Lit := CopyStr(Input, Start, Pos - Start);
        Pos += 1;
    end;

    [TryFunction]
    local procedure ConsumeFieldByNo(Input: Text; var Pos: Integer; var Lit: Text; var ErrorMsg: Text)
    var
        Start: Integer;
    begin
        Pos += 1;
        Start := Pos;
        while (Pos <= StrLen(Input)) and (Input[Pos] in ['0' .. '9']) do Pos += 1;
        if Pos = Start then begin
            ErrorMsg := 'expected digits after #';
            Error('');
        end;
        Lit := CopyStr(Input, Start, Pos - Start);
    end;

    [TryFunction]
    local procedure ConsumeNumberOrDate(Input: Text; var Pos: Integer; var Lit: Text; var ErrorMsg: Text)
    var
        Start: Integer;
    begin
        Start := Pos;
        if Input[Pos] = '-' then Pos += 1;
        while (Pos <= StrLen(Input)) and (Input[Pos] in ['0' .. '9', '.', '-', ':', 'T', 'Z']) do Pos += 1;
        Lit := CopyStr(Input, Start, Pos - Start);
        if Lit = '' then begin
            ErrorMsg := 'expected number';
            Error('');
        end;
    end;

    local procedure ResolveNumericKind(Lit: Text): Text
    begin
        if (StrLen(Lit) >= 10) and (Lit[5] = '-') and (Lit[8] = '-') then
            if StrPos(Lit, 'T') > 0 then exit('datetime') else exit('date');
        exit('number');
    end;

    local procedure IsIdentStart(Ch: Char): Boolean
    begin
        exit((Ch in ['A' .. 'Z']) or (Ch in ['a' .. 'z']) or (Ch = '_'));
    end;

    local procedure IsNextDigit(Input: Text; Pos: Integer): Boolean
    begin
        exit((Pos < StrLen(Input)) and (Input[Pos + 1] in ['0' .. '9']));
    end;

    local procedure ConsumeBareIdent(Input: Text; var Pos: Integer; var Lit: Text)
    var
        Start: Integer;
    begin
        Start := Pos;
        while (Pos <= StrLen(Input)) and (
              (Input[Pos] in ['A' .. 'Z']) or
              (Input[Pos] in ['a' .. 'z']) or
              (Input[Pos] in ['0' .. '9']) or
              (Input[Pos] = '_'))
        do Pos += 1;
        Lit := CopyStr(Input, Start, Pos - Start);
    end;

    local procedure ClassifyKeyword(Lit: Text): Text
    begin
        case LowerCase(Lit) of
            'eq': exit('op_eq');
            'ne': exit('op_ne');
            'gt': exit('op_gt');
            'ge': exit('op_ge');
            'lt': exit('op_lt');
            'le': exit('op_le');
            'and': exit('and');
            'or': exit('or');
            'not': exit('not');
            'in': exit('in');
            'null': exit('null');
            'startswith': exit('fn_startswith');
            'endswith': exit('fn_endswith');
            'contains': exit('fn_contains');
        end;
        exit('ident');
    end;
}
