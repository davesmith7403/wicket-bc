enum 94105 "Bcmag Package Format"
{
    // Serialization of an async query package. NDJSON is the default: one JSON object per line,
    // stream-friendly for arbitrarily large exports. Json wraps the rows in a single array. Zip
    // compresses the NDJSON payload into a single-entry archive (System.IO "Data Compression").
    Extensible = false;

    value(0; Ndjson) { Caption = 'NDJSON'; }
    value(1; Json) { Caption = 'JSON'; }
    value(2; Zip) { Caption = 'ZIP'; }
}
