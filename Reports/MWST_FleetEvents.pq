// MWST fleet events - Power Query import with explicit column types.
//
// How to use:
//   Power BI Desktop > Home > Get data > Blank query > Advanced Editor,
//   paste this whole file, set FilePath below, Done. Rename the query "Events".
//
// Why explicit types and "en-US":
//   The CSV is written culture-invariant (ISO timestamps, "." decimals,
//   TRUE/FALSE). Power BI's automatic type detection uses the report's
//   locale; in a Czech locale it would read 85.5 as text or as 855. Typing
//   every column here with an en-US culture makes the import independent of
//   whoever opens the report.
//
// For scheduled refresh in the Power BI Service (no gateway needed), replace
// the Source step with the SharePoint copy of the same file:
//
//   Source = Csv.Document(
//       Web.Contents("https://<tenant>.sharepoint.com/sites/TEAM-CZDivisionITcka/Shared%20Documents/General/KIOSKS/MWST_FleetEvents.csv"),
//       [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
//
// and sign in with "Organizational account" when prompted.

let
    // The OneDrive-synced SharePoint copy on this PC. On another machine the
    // user folder differs - point it at wherever KIOSKS\ is synced there.
    FilePath = "C:\Users\muzikv\Verplank Enterprises, Inc\TEAM - CZ Division ITcka - General\KIOSKS\MWST_FleetEvents.csv",

    Source = Csv.Document(
//        File.Contents(FilePath),
		Web.Contents("https://shapecorp.sharepoint.com/sites/TEAM-CZDivisionITcka/Shared%20Documents/General/KIOSKS/MWST_FleetEvents.csv"),
        [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),

    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),

    // Empty means "not applicable". Turning it into null before typing keeps
    // blank numbers, dates and booleans from becoming conversion errors.
    Blanks = Table.ReplaceValue(Promoted, "", null, Replacer.ReplaceValue, Table.ColumnNames(Promoted)),

    Typed = Table.TransformColumnTypes(Blanks, {
        {"EventId",             type text},
        {"EventTimeUtc",        type datetimezone},
        {"EventTimeLocal",      type datetime},
        {"EventDate",           type date},
        {"Host",                type text},
        {"Location",            type text},
        {"KioskType",           type text},
        {"RestartGroup",        type text},
        {"EventCategory",       type text},
        {"EventType",           type text},
        {"Severity",            type text},
        {"Outcome",             type text},
        {"IsCanonicalReboot",   type logical},
        {"IsScriptReboot",      type logical},
        {"RebootTrigger",       type text},
        {"WhitePercent",        type number},
        {"StreakChecks",        Int64.Type},
        {"DurationSeconds",     Int64.Type},
        {"Reachable",           type logical},
        {"WatchdogRunning",     type logical},
        {"MinutesSinceLastLog", type number},
        {"AgentVersion",        type text},
        {"BootTimeUtc",         type datetimezone},
        {"UptimeHours",         type number},
        {"Source",              type text},
        {"ScanId",              type text},
        {"CollectedUtc",        type datetimezone},
        {"Detail",              type text}
    }, "en-US")
in
    Typed
