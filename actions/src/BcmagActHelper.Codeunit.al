codeunit 94210 "Bcmag Act Helper"
{
    // Shared argument parsing for the action wrappers — the small, repeated primitives so each
    // action codeunit stays focused on its typed BC call. All getters tolerate a missing/null/
    // non-scalar member (they fall back to the default rather than throwing a 500).
    //
    // NOT shared here: ParseDocType/DocTypeName stay in each document wrapper. "Sales Document
    // Type" and "Purchase Document Type" are distinct enums (no common interface, AL has no
    // generics), so a shared signature would have to pass raw ordinals and rely on the two
    // enums' values happening to coincide — per-wrapper typed copies are safer.

    procedure GetText(Args: JsonObject; Name: Text; var Value: Text): Boolean
    var
        Tok: JsonToken;
    begin
        if not Args.Get(Name, Tok) then
            exit(false);
        // Nested, not or-ed: AL evaluates both operands, so AsValue() would raise on an object.
        if not Tok.IsValue() then
            exit(false);
        if Tok.AsValue().IsNull() then
            exit(false);
        Value := Tok.AsValue().AsText();
        exit(Value <> '');
    end;

    procedure GetTextOr(Args: JsonObject; Name: Text; Default: Text): Text
    var
        Value: Text;
    begin
        if GetText(Args, Name, Value) then
            exit(Value);
        exit(Default);
    end;

    procedure RequireText(Args: JsonObject; Name: Text) Value: Text
    begin
        if not GetText(Args, Name, Value) then
            Error('args.%1 is required', Name);
    end;

    procedure GetBool(Args: JsonObject; Name: Text; Default: Boolean): Boolean
    var
        Tok: JsonToken;
    begin
        if not Args.Get(Name, Tok) then
            exit(Default);
        if not Tok.IsValue() then
            exit(Default);
        if Tok.AsValue().IsNull() then
            exit(Default);
        exit(Tok.AsValue().AsBoolean());
    end;
}
