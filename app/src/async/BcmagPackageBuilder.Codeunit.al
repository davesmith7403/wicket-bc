codeunit 94133 "Bcmag Package Builder"
{
    // Serializes projected query rows into a delivery package Temp Blob. Rows are streamed straight
    // to a Temp Blob OutStream as they arrive, so an arbitrarily large export never has to be held
    // as one in-memory Text. Three formats:
    //   NDJSON — one compact JSON object per line (default, stream-friendly).
    //   JSON   — the same objects wrapped in a single '[' ... ']' array.
    //   ZIP    — the NDJSON payload compressed as a single-entry 'package.ndjson' archive
    //            (System.IO "Data Compression").

    Access = Public;

    var
        PackageTempBlob: Codeunit "Temp Blob";
        PackageOutStr: OutStream;
        PackageFormat: Enum "Bcmag Package Format";
        RowCount: Integer;
        FirstRow: Boolean;

    procedure BeginPackage(NewFormat: Enum "Bcmag Package Format")
    begin
        Clear(PackageTempBlob);
        PackageFormat := NewFormat;
        RowCount := 0;
        FirstRow := true;
        PackageTempBlob.CreateOutStream(PackageOutStr, TextEncoding::UTF8);
        // NDJSON/ZIP need no framing; only the JSON array needs an opening bracket.
        if PackageFormat = PackageFormat::Json then
            PackageOutStr.WriteText('[');
    end;

    procedure AddRow(RowJson: JsonObject)
    var
        RowText: Text;
    begin
        RowJson.WriteTo(RowText); // compact, no pretty-print
        case PackageFormat of
            PackageFormat::Ndjson,
            PackageFormat::Zip:
                begin
                    PackageOutStr.WriteText(RowText);
                    PackageOutStr.WriteText(Lf());
                end;
            PackageFormat::Json:
                begin
                    if not FirstRow then
                        PackageOutStr.WriteText(',');
                    PackageOutStr.WriteText(RowText);
                end;
        end;
        FirstRow := false;
        RowCount += 1;
    end;

    procedure FinishPackage(var ResultTempBlob: Codeunit "Temp Blob"; var ContentType: Text; var RowCountOut: Integer)
    var
        Compression: Codeunit "Data Compression";
        NdjsonInStr: InStream;
    begin
        RowCountOut := RowCount;
        case PackageFormat of
            PackageFormat::Ndjson:
                begin
                    ContentType := 'application/x-ndjson';
                    CopyPackage(ResultTempBlob);
                end;
            PackageFormat::Json:
                begin
                    PackageOutStr.WriteText(']'); // zero rows => '[]'
                    ContentType := 'application/json';
                    CopyPackage(ResultTempBlob);
                end;
            PackageFormat::Zip:
                begin
                    ContentType := 'application/zip';
                    PackageTempBlob.CreateInStream(NdjsonInStr, TextEncoding::UTF8);
                    Compression.CreateZipArchive();
                    Compression.AddEntry(NdjsonInStr, 'package.ndjson');
                    Compression.SaveZipArchive(ResultTempBlob);
                    Compression.CloseZipArchive();
                end;
        end;
    end;

    local procedure CopyPackage(var ResultTempBlob: Codeunit "Temp Blob")
    var
        InStr: InStream;
        OutStr: OutStream;
    begin
        PackageTempBlob.CreateInStream(InStr);
        ResultTempBlob.CreateOutStream(OutStr);
        CopyStream(OutStr, InStr);
    end;

    local procedure Lf(): Text
    var
        C: Char;
    begin
        C := 10;
        exit(Format(C));
    end;
}
