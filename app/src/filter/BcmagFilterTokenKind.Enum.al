enum 94101 "Bcmag Filter Token Kind"
{
    Extensible = false;
    value(0;  Identifier)   { Caption = 'Identifier'; }
    value(1;  StringLit)    { Caption = 'String'; }
    value(2;  NumberLit)    { Caption = 'Number'; }
    value(3;  DateLit)      { Caption = 'Date'; }
    value(4;  DateTimeLit)  { Caption = 'DateTime'; }
    value(5;  NullLit)      { Caption = 'Null'; }
    value(10; OpEq)         { Caption = 'eq'; }
    value(11; OpNe)         { Caption = 'ne'; }
    value(12; OpGt)         { Caption = 'gt'; }
    value(13; OpGe)         { Caption = 'ge'; }
    value(14; OpLt)         { Caption = 'lt'; }
    value(15; OpLe)         { Caption = 'le'; }
    value(20; LogAnd)       { Caption = 'and'; }
    value(21; LogOr)        { Caption = 'or'; }
    value(22; LogNot)       { Caption = 'not'; }
    value(30; LParen)       { Caption = '('; }
    value(31; RParen)       { Caption = ')'; }
    value(40; Comma)        { Caption = 'comma', Locked = true; }
    value(50; FnStartsWith) { Caption = 'startswith'; }
    value(51; FnEndsWith)   { Caption = 'endswith'; }
    value(52; FnContains)   { Caption = 'contains'; }
    value(60; OpIn)         { Caption = 'in'; }
    value(70; FieldByNo)    { Caption = '#fieldNo'; }
}
