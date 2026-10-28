enum 94111 "Bcmag Mask Kind"
{
    // How a mask profile renders a Masked value. KeepLast / KeepFirst / KeepFirstLast reveal the
    // configured ends and replace the middle; Email keeps the first character and the domain; Fixed
    // emits the profile's fixed text; Null emits JSON null; Hash emits a keyed, non-reversible digest
    // (equal inputs give equal outputs, so a caller can correlate without reading the value).
    Extensible = false;
    Caption = 'Wicket Mask Kind';

    value(0; KeepLast)      { Caption = 'Keep Last'; }
    value(1; KeepFirst)     { Caption = 'Keep First'; }
    value(2; KeepFirstLast) { Caption = 'Keep First and Last'; }
    value(3; Email)         { Caption = 'Email'; }
    value(4; Fixed)         { Caption = 'Fixed Text'; }
    value(5; Null)          { Caption = 'Null'; }
    value(6; Hash)          { Caption = 'Hash'; }
}
