codeunit 94110 "Bcmag Filter Applier"
{
    // Walks the filter AST and applies it via FieldRef.SetFilter. Every value reaches BC through
    // one of two safe paths (spec §16 R16):
    //   - comparisons and in-lists: parameterised SetFilter('<op>%1', Value) / SetFilter('%1|%2', ...).
    //     The platform substitutes a %n text value as an EXACT literal — CI-verified:
    //     "No." eq '*' matched only the row whose No. is literally '*' — so no caller metacharacter
    //     (* ? | & ..) can widen an equality, range, or membership test.
    //   - wildcard functions (startswith/endswith/contains): a single-quoted literal with the wildcard
    //     INSIDE the quotes ('Ac*'). The quotes neutralise & ( ) = | — the platform's documented set
    //     ("to filter on records that start with J & V, use 'J & V*'") — but the platform has NO
    //     escape for * and ?: a caller's * or ? inside a text-function value stays a wildcard. That is
    //     documented protocol behaviour, not an injection — it can only widen the caller's own pattern.
    //     A wildcard placed OUTSIDE the quotes ('Ac'*) is a platform syntax error ("Did not expect
    //     value '*'"), which is how the first CI run found this; the same run showed a hand-quoted
    //     in-list member '*' matching every row, which is why in-lists moved to %n parameters.

    var
        Resolver: Codeunit "Bcmag Field Name Resolver";
        FieldPolicy: Codeunit "Bcmag Field Policy";

    procedure Apply(var RecRef: RecordRef; Ast: JsonObject; var ErrorMsg: Text): Boolean
    var
        Leaves: JsonArray;
        LeafFieldNos: List of [Integer];
        DoneFields: List of [Integer];
        LeafTok: JsonToken;
        FieldNo, i: Integer;
    begin
        // Flatten the AND tree into leaf conditions (rejecting or / not / empty in-list), then group
        // them by target field. FieldRef.SetFilter REPLACES any existing filter on a field, so two
        // conditions on the SAME field (e.g. a date range "ge X and le Y") must be composed into one
        // SetFilter — applying them independently would silently drop the earlier one and widen the
        // result. Conditions on DISTINCT fields are still ANDed by BC automatically.
        if not CollectLeaves(Ast, Leaves, ErrorMsg) then exit(false);

        for i := 0 to Leaves.Count() - 1 do begin
            Leaves.Get(i, LeafTok);
            if not LeafFieldNo(RecRef, LeafTok.AsObject(), FieldNo, ErrorMsg) then exit(false);
            LeafFieldNos.Add(FieldNo); // position i+1 mirrors Leaves index i
        end;

        for i := 0 to Leaves.Count() - 1 do begin
            FieldNo := LeafFieldNos.Get(i + 1);
            if not DoneFields.Contains(FieldNo) then begin
                DoneFields.Add(FieldNo);
                if not SafeApplyFieldGroup(RecRef, Leaves, LeafFieldNos, FieldNo, ErrorMsg) then exit(false);
            end;
        end;
        exit(true);
    end;

    // SetFilter throws when a literal is incompatible with the field type (e.g. a non-numeric value
    // on a numeric field). Catch it so the caller returns a 400 invalid-filter rather than letting
    // the raw AL error surface as a 500. A graceful (returned) failure keeps its own ErrorMsg.
    local procedure SafeApplyFieldGroup(var RecRef: RecordRef; Leaves: JsonArray; LeafFieldNos: List of [Integer]; FieldNo: Integer; var ErrorMsg: Text): Boolean
    var
        InnerErr: Text;
        GroupOk: Boolean;
    begin
        if not TryApplyFieldGroup(RecRef, Leaves, LeafFieldNos, FieldNo, InnerErr, GroupOk) then begin
            ErrorMsg := StrSubstNo('a filter value is not valid for the target field type (%1)', GetLastErrorText());
            exit(false);
        end;
        ErrorMsg := InnerErr;
        exit(GroupOk);
    end;

    [TryFunction]
    local procedure TryApplyFieldGroup(var RecRef: RecordRef; Leaves: JsonArray; LeafFieldNos: List of [Integer]; FieldNo: Integer; var InnerErr: Text; var GroupOk: Boolean)
    begin
        GroupOk := ApplyFieldGroup(RecRef, Leaves, LeafFieldNos, FieldNo, InnerErr);
    end;

    // Walk the AST, pushing each leaf condition (binop / func / in) into Leaves. ANDs are flattened;
    // or / not are rejected (unchanged from v1), and an empty in-list is rejected here rather than
    // compiling to SetFilter('') which would clear the field filter and match every row.
    local procedure CollectLeaves(Node: JsonObject; var Leaves: JsonArray; var ErrorMsg: Text): Boolean
    var
        Tok: JsonToken;
        NodeType, OpName: Text;
        Values: JsonArray;
    begin
        Node.Get('node', Tok);
        NodeType := Tok.AsValue().AsText();
        case NodeType of
            'binop', 'func':
                begin
                    Leaves.Add(Node.AsToken());
                    exit(true);
                end;
            'in':
                begin
                    Node.Get('values', Tok);
                    Values := Tok.AsArray();
                    if Values.Count() = 0 then begin
                        ErrorMsg := 'in (...) requires at least one value';
                        exit(false);
                    end;
                    Leaves.Add(Node.AsToken());
                    exit(true);
                end;
            'logical':
                begin
                    Node.Get('op', Tok);
                    OpName := Tok.AsValue().AsText();
                    if OpName = 'and' then begin
                        Node.Get('left', Tok);
                        if not CollectLeaves(Tok.AsObject(), Leaves, ErrorMsg) then exit(false);
                        Node.Get('right', Tok);
                        exit(CollectLeaves(Tok.AsObject(), Leaves, ErrorMsg));
                    end;
                    // BC's per-field SetFilter model ANDs across fields; cross-field OR
                    // cannot be expressed this way. Same-field OR is handled by `in`.
                    ErrorMsg := 'cross-field "or" is not supported in v1; use "in (...)" for same-field disjunction, or split into multiple queries';
                    exit(false);
                end;
            'not':
                begin
                    ErrorMsg := 'standalone "not" is not supported in v1; use "ne", or invert the comparison';
                    exit(false);
                end;
        end;
        ErrorMsg := StrSubstNo('unsupported AST node %1', NodeType);
        exit(false);
    end;

    local procedure LeafFieldNo(var RecRef: RecordRef; Node: JsonObject; var FieldNo: Integer; var ErrorMsg: Text): Boolean
    var
        Tok: JsonToken;
        FieldRefVal: FieldRef;
    begin
        Node.Get('field', Tok);
        if not ResolveFieldRef(RecRef, Tok.AsObject(), FieldRefVal, ErrorMsg) then exit(false);
        FieldNo := FieldRefVal.Number;
        exit(true);
    end;

    // Apply every leaf that targets one field. A single condition uses the normal typed path; two
    // comparisons compose into one SetFilter (a range); anything else on the same field is rejected.
    local procedure ApplyFieldGroup(var RecRef: RecordRef; Leaves: JsonArray; LeafFieldNos: List of [Integer]; FieldNo: Integer; var ErrorMsg: Text): Boolean
    var
        GroupIdx: List of [Integer];
        LeafA, LeafB: JsonToken;
        i: Integer;
    begin
        for i := 0 to Leaves.Count() - 1 do
            if LeafFieldNos.Get(i + 1) = FieldNo then
                GroupIdx.Add(i);

        case GroupIdx.Count() of
            1:
                begin
                    Leaves.Get(GroupIdx.Get(1), LeafA);
                    exit(ApplyLeaf(RecRef, LeafA.AsObject(), ErrorMsg));
                end;
            2:
                begin
                    Leaves.Get(GroupIdx.Get(1), LeafA);
                    Leaves.Get(GroupIdx.Get(2), LeafB);
                    exit(ApplyTwoComparisons(RecRef, LeafA.AsObject(), LeafB.AsObject(), ErrorMsg));
                end;
            else begin
                ErrorMsg := StrSubstNo('a field appears in %1 conditions; only a single condition or a two-comparison range is supported per field — split into separate queries', GroupIdx.Count());
                exit(false);
            end;
        end;
    end;

    local procedure ApplyLeaf(var RecRef: RecordRef; Node: JsonObject; var ErrorMsg: Text): Boolean
    var
        Tok: JsonToken;
        NodeType: Text;
    begin
        Node.Get('node', Tok);
        NodeType := Tok.AsValue().AsText();
        case NodeType of
            'binop':
                exit(ApplyBinop(RecRef, Node, ErrorMsg));
            'func':
                exit(ApplyFunc(RecRef, Node, ErrorMsg));
            'in':
                exit(ApplyIn(RecRef, Node, ErrorMsg));
        end;
        ErrorMsg := StrSubstNo('unsupported AST node %1', NodeType);
        exit(false);
    end;

    // Compose two comparisons on the same field into one SetFilter('<sym1>%1&<sym2>%2', v1, v2).
    // Restricted to numeric/temporal comparisons so the values pass as typed %1/%2 (no locale or
    // injection risk). Any other same-field pairing (func, in, null, text, mixed kinds) is rejected.
    local procedure ApplyTwoComparisons(var RecRef: RecordRef; NodeA: JsonObject; NodeB: JsonObject; var ErrorMsg: Text): Boolean
    var
        Tok: JsonToken;
        FieldRefVal: FieldRef;
        opA, opB, kindA, kindB, textA, textB, symA, symB: Text;
        DecA, DecB: Decimal;
        DateA, DateB: Date;
        DtA, DtB: DateTime;
    begin
        if not (IsRangeComparison(NodeA, opA, kindA, textA) and IsRangeComparison(NodeB, opB, kindB, textB)) then begin
            ErrorMsg := 'multiple conditions on the same field are supported only as a numeric or date/time range (two comparisons); split other combinations into separate queries';
            exit(false);
        end;
        if kindA <> kindB then begin
            ErrorMsg := 'a same-field range must use two values of the same kind';
            exit(false);
        end;

        NodeA.Get('field', Tok);
        if not ResolveFieldRef(RecRef, Tok.AsObject(), FieldRefVal, ErrorMsg) then exit(false);
        symA := OpSymbol(opA);
        symB := OpSymbol(opB);

        case kindA of
            'number':
                begin
                    if not (Evaluate(DecA, textA, 9) and Evaluate(DecB, textB, 9)) then begin
                        ErrorMsg := 'invalid number in a same-field range';
                        exit(false);
                    end;
                    FieldRefVal.SetFilter(symA + '%1&' + symB + '%2', DecA, DecB);
                end;
            'date':
                begin
                    if not (Evaluate(DateA, textA, 9) and Evaluate(DateB, textB, 9)) then begin
                        ErrorMsg := 'invalid date in a same-field range';
                        exit(false);
                    end;
                    FieldRefVal.SetFilter(symA + '%1&' + symB + '%2', DateA, DateB);
                end;
            'datetime':
                begin
                    if not (Evaluate(DtA, textA, 9) and Evaluate(DtB, textB, 9)) then begin
                        ErrorMsg := 'invalid datetime in a same-field range';
                        exit(false);
                    end;
                    FieldRefVal.SetFilter(symA + '%1&' + symB + '%2', DtA, DtB);
                end;
            else begin
                ErrorMsg := 'a same-field range is supported only for number, date, or datetime fields';
                exit(false);
            end;
        end;
        exit(true);
    end;

    // True when Node is a plain comparison (eq/ne/gt/ge/lt/le) on a numeric/temporal literal — the
    // only shape that can be safely composed into a combined typed filter.
    local procedure IsRangeComparison(Node: JsonObject; var Op: Text; var Kind: Text; var ValText: Text): Boolean
    var
        Tok: JsonToken;
        ValueNode: JsonObject;
    begin
        Node.Get('node', Tok);
        if Tok.AsValue().AsText() <> 'binop' then exit(false);
        Node.Get('op', Tok);
        Op := Tok.AsValue().AsText();
        if OpSymbol(Op) = '' then exit(false);
        Node.Get('value', Tok);
        ValueNode := Tok.AsObject();
        ValueNode.Get('kind', Tok);
        Kind := Tok.AsValue().AsText();
        ValueNode.Get('value', Tok);
        ValText := Tok.AsValue().AsText();
        exit(Kind in ['number', 'date', 'datetime']);
    end;

    local procedure ResolveFieldRef(var RecRef: RecordRef; FieldNode: JsonObject; var FieldRefOut: FieldRef; var ErrorMsg: Text): Boolean
    var
        Tok: JsonToken;
        Kind, Value: Text;
        FieldNo: Integer;
        Suggestion: Text;
    begin
        FieldNode.Get('kind', Tok);
        Kind := Tok.AsValue().AsText();
        FieldNode.Get('value', Tok);
        Value := Tok.AsValue().AsText();
        case Kind of
            'fieldNo':
                if not Evaluate(FieldNo, Value) then begin
                    ErrorMsg := 'invalid #fieldNo';
                    exit(false);
                end;
            'ident':
                if not Resolver.ResolveByName(RecRef.Number, Value, FieldNo, Suggestion) then begin
                    if Suggestion <> '' then
                        ErrorMsg := StrSubstNo('unknown field "%1" — did you mean "%2"?', Value, Suggestion)
                    else
                        ErrorMsg := StrSubstNo('unknown field "%1"', Value);
                    exit(false);
                end;
        end;
        if not RecRef.FieldExist(FieldNo) then begin
            ErrorMsg := StrSubstNo('field %1 does not exist on table %2', FieldNo, RecRef.Number);
            exit(false);
        end;
        // Field policy at resolution time: a filter on a restricted field is refused — silently
        // ignoring it would still leak row membership through the result set. The marker prefix
        // makes the query handler surface this as 403 'field-restricted', not 400 'invalid-filter'.
        // The field is named by NUMBER, not name: this branch also serves #fieldNo filters, and
        // the field name would disclose a restricted field to a caller who supplied a number.
        if not FieldPolicy.IsReadable(RecRef.Number, FieldNo) then begin
            ErrorMsg := FieldPolicy.RestrictedMarker() +
                StrSubstNo('field %1 is not readable under the current field policy', FieldNo);
            exit(false);
        end;
        // A masked field is readable (shown as its mask) but a filter on it is a row-membership
        // oracle: `Name eq 'x'` or startswith(Name,'P') would reconstruct the hidden value. Every
        // leaf (comparison, startswith/contains/in, null tests, range pairs) resolves through here.
        if FieldPolicy.IsMasked(RecRef.Number, FieldNo) then begin
            ErrorMsg := FieldPolicy.MaskedMarker() +
                StrSubstNo('field %1 is masked and cannot be filtered on', FieldNo);
            exit(false);
        end;
        FieldRefOut := RecRef.Field(FieldNo);
        exit(true);
    end;

    local procedure ApplyBinop(var RecRef: RecordRef; Node: JsonObject; var ErrorMsg: Text): Boolean
    var
        Tok: JsonToken;
        FieldNode, ValueNode: JsonObject;
        FieldRefVal: FieldRef;
        Op, ValKind, ValText: Text;
    begin
        Node.Get('field', Tok);
        FieldNode := Tok.AsObject();
        Node.Get('value', Tok);
        ValueNode := Tok.AsObject();
        Node.Get('op', Tok);
        Op := Tok.AsValue().AsText();

        ValueNode.Get('kind', Tok);
        ValKind := Tok.AsValue().AsText();
        ValueNode.Get('value', Tok);
        ValText := Tok.AsValue().AsText();

        if not ResolveFieldRef(RecRef, FieldNode, FieldRefVal, ErrorMsg) then exit(false);

        if (ValKind = 'null') or ((ValKind = 'string') and (ValText = '')) then
            exit(ApplyNull(FieldRefVal, Op, ErrorMsg));

        exit(ApplyComparison(FieldRefVal, Op, ValKind, ValText, ErrorMsg));
    end;

    local procedure ApplyComparison(var FieldRefVal: FieldRef; Op: Text; ValKind: Text; ValText: Text; var ErrorMsg: Text): Boolean
    var
        Sym: Text;
        DecV: Decimal;
        DateV: Date;
        DtV: DateTime;
        BoolV: Boolean;
    begin
        Sym := OpSymbol(Op);
        if Sym = '' then begin
            ErrorMsg := StrSubstNo('unsupported comparison operator "%1"', Op);
            exit(false);
        end;

        // A numeric literal against a Code/Text field ("No." eq 10000) is the literal's TEXT: a Decimal
        // %1 would be formatted in the session locale (10,000 / 10.000) and match nothing.
        if (ValKind = 'number') and IsTextual(FieldRefVal) then
            ValKind := 'string';

        case ValKind of
            'number':
                begin
                    if not Evaluate(DecV, ValText, 9) then begin
                        ErrorMsg := StrSubstNo('"%1" is not a valid number', ValText);
                        exit(false);
                    end;
                    FieldRefVal.SetFilter(Sym + '%1', DecV);
                end;
            'date':
                begin
                    if not Evaluate(DateV, ValText, 9) then begin
                        ErrorMsg := StrSubstNo('"%1" is not a valid date (expected YYYY-MM-DD)', ValText);
                        exit(false);
                    end;
                    FieldRefVal.SetFilter(Sym + '%1', DateV);
                end;
            'datetime':
                begin
                    if not Evaluate(DtV, ValText, 9) then begin
                        ErrorMsg := StrSubstNo('"%1" is not a valid datetime (expected RFC 3339 UTC)', ValText);
                        exit(false);
                    end;
                    FieldRefVal.SetFilter(Sym + '%1', DtV);
                end;
            'bool':
                begin
                    // Bool literals support only eq/ne on Boolean fields. A Boolean field has
                    // no third state, so ne is folded to a SetRange on the opposite value —
                    // no text ever reaches the filter expression.
                    if not (Op in ['eq', 'ne']) then begin
                        ErrorMsg := StrSubstNo('operator "%1" cannot be used with a boolean literal; use eq or ne', Op);
                        exit(false);
                    end;
                    if FieldRefVal.Type <> FieldType::Boolean then begin
                        ErrorMsg := StrSubstNo('boolean literal %1 can only be compared to a Boolean field', ValText);
                        exit(false);
                    end;
                    BoolV := ValText = 'true';
                    if Op = 'ne' then
                        BoolV := not BoolV;
                    FieldRefVal.SetRange(BoolV);
                end;
            else
                // Text/Code/Option/GUID — pass as a parameterised text value (escaped by %1).
                FieldRefVal.SetFilter(Sym + '%1', ValText);
        end;
        exit(true);
    end;

    local procedure ApplyNull(var FieldRefVal: FieldRef; Op: Text; var ErrorMsg: Text): Boolean
    var
        Sym: Text;
    begin
        case Op of
            'eq':
                Sym := '=';
            'ne':
                Sym := '<>';
            else begin
                ErrorMsg := StrSubstNo('operator "%1" cannot be used with null', Op);
                exit(false);
            end;
        end;
        case FieldRefVal.Type of
            FieldType::Date:
                FieldRefVal.SetFilter(Sym + '%1', 0D);
            FieldType::DateTime:
                FieldRefVal.SetFilter(Sym + '%1', 0DT);
            FieldType::Time:
                FieldRefVal.SetFilter(Sym + '%1', 0T);
            FieldType::Integer, FieldType::Decimal, FieldType::BigInteger:
                FieldRefVal.SetFilter(Sym + '%1', 0);
            else
                FieldRefVal.SetFilter(Sym + '%1', '');
        end;
        exit(true);
    end;

    local procedure ApplyFunc(var RecRef: RecordRef; Node: JsonObject; var ErrorMsg: Text): Boolean
    var
        Tok: JsonToken;
        FieldNode, ValueNode: JsonObject;
        FieldRefVal: FieldRef;
        Fn, ValText, Lit: Text;
    begin
        Node.Get('fn', Tok);
        Fn := Tok.AsValue().AsText();
        Node.Get('field', Tok);
        FieldNode := Tok.AsObject();
        Node.Get('value', Tok);
        ValueNode := Tok.AsObject();
        ValueNode.Get('value', Tok);
        ValText := Tok.AsValue().AsText();

        if not ResolveFieldRef(RecRef, FieldNode, FieldRefVal, ErrorMsg) then exit(false);

        // The wildcard must sit INSIDE the quoted literal — 'Ac*' — never outside ('Ac'*), which BC
        // rejects as a syntax error. Embedded quotes are doubled; see the header for what the quotes
        // do and do not neutralise.
        Lit := ValText.Replace('''', '''''');
        case Fn of
            'startswith':
                FieldRefVal.SetFilter('''' + Lit + '*''');
            'endswith':
                FieldRefVal.SetFilter('''*' + Lit + '''');
            'contains':
                FieldRefVal.SetFilter('''*' + Lit + '*''');
            else begin
                ErrorMsg := StrSubstNo('unsupported function "%1"', Fn);
                exit(false);
            end;
        end;
        exit(true);
    end;

    local procedure ApplyIn(var RecRef: RecordRef; Node: JsonObject; var ErrorMsg: Text): Boolean
    var
        Tok: JsonToken;
        FieldNode: JsonObject;
        Values: JsonArray;
        FieldRefVal: FieldRef;
        i: Integer;
        ValTok: JsonToken;
        ValueNode: JsonObject;
        Kind, ValText: Text;
        Members: array[20] of Variant;
    begin
        Node.Get('field', Tok);
        FieldNode := Tok.AsObject();
        Node.Get('values', Tok);
        Values := Tok.AsArray();
        if not ResolveFieldRef(RecRef, FieldNode, FieldRefVal, ErrorMsg) then exit(false);

        if Values.Count() = 0 then begin
            // Defensive: an empty list would make SetFilter('') CLEAR the field filter (match all
            // rows). CollectLeaves already rejects this, but never let it reach SetFilter.
            ErrorMsg := 'in (...) requires at least one value';
            exit(false);
        end;
        if Values.Count() > MaxInMembers() then begin
            ErrorMsg := StrSubstNo('in (...) accepts at most %1 values (got %2); split the list across queries', MaxInMembers(), Values.Count());
            exit(false);
        end;
        // Each member is converted to its TYPED value by literal kind, with the invariant parse
        // (Evaluate(..., 9)) — exactly what a single comparison does in ApplyComparison. Passing the
        // raw literal TEXT as %n would make the platform re-parse it in the session's locale, so
        // `Amount in (1.5, 2.5)` would read 1.5 as fifteen under a comma-decimal region, and a date
        // literal would depend on the session's date order. A typed %n value is substituted as that
        // value, never re-parsed.
        for i := 0 to Values.Count() - 1 do begin
            Values.Get(i, ValTok);
            ValueNode := ValTok.AsObject();
            ValueNode.Get('kind', Tok);
            Kind := Tok.AsValue().AsText();
            ValueNode.Get('value', Tok);
            ValText := Tok.AsValue().AsText();
            if (Kind = 'number') and IsTextual(FieldRefVal) then
                Kind := 'string'; // as in ApplyComparison: a Code/Text field compares the literal text
            if not TypedMember(Kind, ValText, Members[i + 1], ErrorMsg) then exit(false);
        end;
        // Every member travels as a %n parameter (an exact literal — see the header), never as a
        // hand-quoted string: a hand-quoted '*' member is a wildcard and matched every row in CI.
        // AL has no variadic call, so the arity is spelled out up to MaxInMembers.
        SetInFilter(FieldRefVal, Members, Values.Count());
        exit(true);
    end;

    local procedure IsTextual(var FieldRefVal: FieldRef): Boolean
    begin
        exit(FieldRefVal.Type in [FieldType::Code, FieldType::Text]);
    end;

    local procedure TypedMember(Kind: Text; ValText: Text; var Member: Variant; var ErrorMsg: Text): Boolean
    var
        DecV: Decimal;
        DateV: Date;
        DtV: DateTime;
    begin
        case Kind of
            'number':
                begin
                    if not Evaluate(DecV, ValText, 9) then begin
                        ErrorMsg := StrSubstNo('"%1" is not a valid number', ValText);
                        exit(false);
                    end;
                    Member := DecV;
                end;
            'date':
                begin
                    if not Evaluate(DateV, ValText, 9) then begin
                        ErrorMsg := StrSubstNo('"%1" is not a valid date (expected YYYY-MM-DD)', ValText);
                        exit(false);
                    end;
                    Member := DateV;
                end;
            'datetime':
                begin
                    if not Evaluate(DtV, ValText, 9) then begin
                        ErrorMsg := StrSubstNo('"%1" is not a valid datetime (expected RFC 3339 UTC)', ValText);
                        exit(false);
                    end;
                    Member := DtV;
                end;
            'string':
                Member := ValText;
            else begin
                // null has no single-value meaning inside a membership list (the parser already
                // refuses it); use "F eq null" instead.
                ErrorMsg := StrSubstNo('%1 is not allowed inside in (...); use "eq null" for an empty-value test', Kind);
                exit(false);
            end;
        end;
        exit(true);
    end;

    // Upper bound on in (...) members — the SetFilter arity SetInFilter spells out. Advertised in
    // capabilities.limits.maxInMembers so an agent can chunk a long list instead of guessing.
    procedure MaxInMembers(): Integer
    begin
        exit(20);
    end;

    local procedure SetInFilter(var F: FieldRef; M: array[20] of Variant; Count: Integer)
    begin
        case Count of
            1:
                F.SetFilter('%1', M[1]);
            2:
                F.SetFilter('%1|%2', M[1], M[2]);
            3:
                F.SetFilter('%1|%2|%3', M[1], M[2], M[3]);
            4:
                F.SetFilter('%1|%2|%3|%4', M[1], M[2], M[3], M[4]);
            5:
                F.SetFilter('%1|%2|%3|%4|%5', M[1], M[2], M[3], M[4], M[5]);
            6:
                F.SetFilter('%1|%2|%3|%4|%5|%6', M[1], M[2], M[3], M[4], M[5], M[6]);
            7:
                F.SetFilter('%1|%2|%3|%4|%5|%6|%7', M[1], M[2], M[3], M[4], M[5], M[6], M[7]);
            8:
                F.SetFilter('%1|%2|%3|%4|%5|%6|%7|%8', M[1], M[2], M[3], M[4], M[5], M[6], M[7], M[8]);
            9:
                F.SetFilter('%1|%2|%3|%4|%5|%6|%7|%8|%9', M[1], M[2], M[3], M[4], M[5], M[6], M[7], M[8], M[9]);
            10:
                F.SetFilter('%1|%2|%3|%4|%5|%6|%7|%8|%9|%10', M[1], M[2], M[3], M[4], M[5], M[6], M[7], M[8], M[9], M[10]);
            11:
                F.SetFilter('%1|%2|%3|%4|%5|%6|%7|%8|%9|%10|%11', M[1], M[2], M[3], M[4], M[5], M[6], M[7], M[8], M[9], M[10], M[11]);
            12:
                F.SetFilter('%1|%2|%3|%4|%5|%6|%7|%8|%9|%10|%11|%12', M[1], M[2], M[3], M[4], M[5], M[6], M[7], M[8], M[9], M[10], M[11], M[12]);
            13:
                F.SetFilter('%1|%2|%3|%4|%5|%6|%7|%8|%9|%10|%11|%12|%13', M[1], M[2], M[3], M[4], M[5], M[6], M[7], M[8], M[9], M[10], M[11], M[12], M[13]);
            14:
                F.SetFilter('%1|%2|%3|%4|%5|%6|%7|%8|%9|%10|%11|%12|%13|%14', M[1], M[2], M[3], M[4], M[5], M[6], M[7], M[8], M[9], M[10], M[11], M[12], M[13], M[14]);
            15:
                F.SetFilter('%1|%2|%3|%4|%5|%6|%7|%8|%9|%10|%11|%12|%13|%14|%15', M[1], M[2], M[3], M[4], M[5], M[6], M[7], M[8], M[9], M[10], M[11], M[12], M[13], M[14], M[15]);
            16:
                F.SetFilter('%1|%2|%3|%4|%5|%6|%7|%8|%9|%10|%11|%12|%13|%14|%15|%16', M[1], M[2], M[3], M[4], M[5], M[6], M[7], M[8], M[9], M[10], M[11], M[12], M[13], M[14], M[15], M[16]);
            17:
                F.SetFilter('%1|%2|%3|%4|%5|%6|%7|%8|%9|%10|%11|%12|%13|%14|%15|%16|%17', M[1], M[2], M[3], M[4], M[5], M[6], M[7], M[8], M[9], M[10], M[11], M[12], M[13], M[14], M[15], M[16], M[17]);
            18:
                F.SetFilter('%1|%2|%3|%4|%5|%6|%7|%8|%9|%10|%11|%12|%13|%14|%15|%16|%17|%18', M[1], M[2], M[3], M[4], M[5], M[6], M[7], M[8], M[9], M[10], M[11], M[12], M[13], M[14], M[15], M[16], M[17], M[18]);
            19:
                F.SetFilter('%1|%2|%3|%4|%5|%6|%7|%8|%9|%10|%11|%12|%13|%14|%15|%16|%17|%18|%19', M[1], M[2], M[3], M[4], M[5], M[6], M[7], M[8], M[9], M[10], M[11], M[12], M[13], M[14], M[15], M[16], M[17], M[18], M[19]);
            20:
                F.SetFilter('%1|%2|%3|%4|%5|%6|%7|%8|%9|%10|%11|%12|%13|%14|%15|%16|%17|%18|%19|%20', M[1], M[2], M[3], M[4], M[5], M[6], M[7], M[8], M[9], M[10], M[11], M[12], M[13], M[14], M[15], M[16], M[17], M[18], M[19], M[20]);
        end;
    end;

    local procedure OpSymbol(Op: Text): Text
    begin
        case Op of
            'eq':
                exit('=');
            'ne':
                exit('<>');
            'gt':
                exit('>');
            'ge':
                exit('>=');
            'lt':
                exit('<');
            'le':
                exit('<=');
        end;
        exit('');
    end;
}
