param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$projectFile = Join-Path $ProjectRoot 'PhoneTracker.xcodeproj/project.pbxproj'
$pbx = Get-Content -Raw -LiteralPath $projectFile
$definitions = [regex]::Matches($pbx, '(?m)^\s*([A-F0-9]{24}) = \{ isa = ')
$ids = @($definitions | ForEach-Object { $_.Groups[1].Value })
if (($ids | Select-Object -Unique).Count -ne $ids.Count) { throw 'Duplicate Xcode object IDs' }
foreach ($reference in [regex]::Matches($pbx, '\b[A-F0-9]{24}\b')) {
    if ($ids -notcontains $reference.Value) { throw "Unresolved Xcode reference: $($reference.Value)" }
}
foreach ($source in Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'PhoneTracker') -Filter '*.swift') {
    if (-not $pbx.Contains("path = $($source.Name);")) { throw "Source not in Xcode project: $($source.Name)" }
}
$xmlFiles = @('PhoneTracker/Info.plist', 'PhoneTracker/PrivacyInfo.xcprivacy', 'PhoneTracker.xcodeproj/xcshareddata/xcschemes/PhoneTracker.xcscheme')
foreach ($file in $xmlFiles) {
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Ignore
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create((Join-Path $ProjectRoot $file), $settings)
    try { while ($reader.Read()) {} } finally { $reader.Dispose() }
}
$store = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'PhoneTracker/LocationStore.swift')
$limit = [regex]::Match($store, 'maximumRecords = ([\d_]+)').Groups[1].Value.Replace('_', '')
if ($limit -ne '80000') { throw 'Unexpected SQLite cap' }
$schema = [regex]::Match($store, '(CREATE TABLE IF NOT EXISTS phone_locations[\s\S]*?)"""').Groups[1].Value.Trim()
$index = [regex]::Match($store, '"(CREATE INDEX IF NOT EXISTS[^"]+)"').Groups[1].Value
$trim = [regex]::Match($store, '"(DELETE FROM phone_locations[^"]+)"').Groups[1].Value.Replace('\(Self.maximumRecords)', $limit)
if (-not $schema -or -not $index -or -not $trim) { throw 'Cannot extract actual Swift SQLite SQL' }
$seed = @"
WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<80005)
INSERT INTO phone_locations(recorded_at,location_at,latitude,longitude,raw_latitude,raw_longitude,
accuracy_meters,motion_state,session_id,display_latitude,display_longitude,display_source,display_location_at)
SELECT x,x,25,121,25,121,4,'moving','seed',25,121,'pipeline',x FROM n;
"@
$sql = @"
$schema;
$index;
$seed
BEGIN IMMEDIATE;
$trim;
COMMIT;
SELECT count(*),min(id),max(id) FROM phone_locations;
BEGIN IMMEDIATE;
INSERT INTO phone_locations(recorded_at,location_at,latitude,longitude,raw_latitude,raw_longitude,
accuracy_meters,motion_state,session_id,display_latitude,display_longitude,display_source,display_location_at)
VALUES(80006,80006,25,121,25,121,4,'moving','new',25,121,'pipeline',80006);
$trim;
COMMIT;
SELECT count(*),min(id),max(id) FROM phone_locations;
SELECT count(*),min(id),max(id) FROM (SELECT id FROM phone_locations ORDER BY recorded_at DESC,id DESC LIMIT 8000);
"@
$results = @($sql | sqlite3 :memory:)
if ($LASTEXITCODE -ne 0) { throw 'SQLite CLI failed' }
if ($results.Count -ne 3 -or $results[0] -ne '80000|6|80005' -or $results[1] -ne '80000|7|80006' -or $results[2] -ne '8000|72007|80006') {
    throw "SQLite verification failed: $results"
}
$report = @(
    'PASS: Xcode object IDs are unique and all references resolve.',
    'PASS: All Swift app source files are included in the project.',
    'PASS: Info.plist, privacy manifest and shared scheme are valid XML.',
    'PASS: Actual Swift SQLite schema and index execute successfully.',
    'PASS: 80,000 newest records retained after trimming and another insert.',
    'PASS: Historical query retains the newest 8,000 records.',
    'NOT RUN: Xcode iOS compilation, XCTest and iPhone device validation (Windows has no iOS SDK).'
)
$report
[IO.File]::WriteAllLines((Join-Path $ProjectRoot 'VALIDATION.txt'), $report, [Text.UTF8Encoding]::new($false))
