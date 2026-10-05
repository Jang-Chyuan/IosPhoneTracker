param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$projectDir = Join-Path $ProjectRoot 'PhoneTracker.xcodeproj'
$schemeDir = Join-Path $projectDir 'xcshareddata/xcschemes'
New-Item -ItemType Directory -Force -Path $schemeDir | Out-Null
$script:nextId = 1
$objects = [Text.StringBuilder]::new()
function New-Id { $id = $script:nextId.ToString('X24'); $script:nextId++; return $id }
function Add-Object([string]$id, [string]$body) { [void]$objects.AppendLine("`t`t$id = { $body }; ") }
$project = New-Id; $mainGroup = New-Id; $sourcesGroup = New-Id; $testsGroup = New-Id; $productsGroup = New-Id
$appTarget = New-Id; $testTarget = New-Id; $appProduct = New-Id; $testProduct = New-Id
$appSources = New-Id; $testSources = New-Id; $resources = New-Id; $testResources = New-Id; $frameworks = New-Id; $testFrameworks = New-Id
$projectConfigList = New-Id; $appConfigList = New-Id; $testConfigList = New-Id
$dependency = New-Id; $proxy = New-Id
$sourceReferences = @(); $sourceBuilds = @()
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'PhoneTracker') -Filter '*.swift' | Sort-Object Name) {
    $reference = New-Id; $build = New-Id
    Add-Object $reference "isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = $($file.Name); sourceTree = `"<group>`";"
    Add-Object $build "isa = PBXBuildFile; fileRef = $reference;"
    $sourceReferences += $reference; $sourceBuilds += $build
}
$plistRef = New-Id; $privacyRef = New-Id; $privacyBuild = New-Id; $testRef = New-Id; $testBuild = New-Id
Add-Object $plistRef 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>";'
Add-Object $privacyRef 'isa = PBXFileReference; lastKnownFileType = text.xml; path = PrivacyInfo.xcprivacy; sourceTree = "<group>";'
Add-Object $privacyBuild "isa = PBXBuildFile; fileRef = $privacyRef;"
Add-Object $testRef 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = TrackingTests.swift; sourceTree = "<group>";'
Add-Object $testBuild "isa = PBXBuildFile; fileRef = $testRef;"
Add-Object $mainGroup "isa = PBXGroup; children = ($sourcesGroup, $testsGroup, $productsGroup,); sourceTree = `"<group>`";"
Add-Object $sourcesGroup "isa = PBXGroup; children = ($($sourceReferences -join ', '), $plistRef, $privacyRef,); path = PhoneTracker; sourceTree = `"<group>`";"
Add-Object $testsGroup "isa = PBXGroup; children = ($testRef,); path = PhoneTrackerTests; sourceTree = `"<group>`";"
Add-Object $productsGroup "isa = PBXGroup; children = ($appProduct, $testProduct,); name = Products; sourceTree = `"<group>`";"
Add-Object $appProduct 'isa = PBXFileReference; explicitFileType = wrapper.application; path = PhoneTracker.app; sourceTree = BUILT_PRODUCTS_DIR;'
Add-Object $testProduct 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = PhoneTrackerTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;'
Add-Object $appSources "isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ($($sourceBuilds -join ', '),); runOnlyForDeploymentPostprocessing = 0;"
Add-Object $testSources "isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ($testBuild,); runOnlyForDeploymentPostprocessing = 0;"
Add-Object $resources "isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ($privacyBuild,); runOnlyForDeploymentPostprocessing = 0;"
foreach ($empty in @($testResources, $frameworks, $testFrameworks)) {
    $type = if ($empty -eq $testResources) { 'PBXResourcesBuildPhase' } else { 'PBXFrameworksBuildPhase' }
    Add-Object $empty "isa = $type; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;"
}
Add-Object $proxy "isa = PBXContainerItemProxy; containerPortal = $project; proxyType = 1; remoteGlobalIDString = $appTarget; remoteInfo = PhoneTracker;"
Add-Object $dependency "isa = PBXTargetDependency; target = $appTarget; targetProxy = $proxy;"
Add-Object $appTarget "isa = PBXNativeTarget; buildConfigurationList = $appConfigList; buildPhases = ($appSources, $frameworks, $resources,); buildRules = (); dependencies = (); name = PhoneTracker; productName = PhoneTracker; productReference = $appProduct; productType = `"com.apple.product-type.application`";"
Add-Object $testTarget "isa = PBXNativeTarget; buildConfigurationList = $testConfigList; buildPhases = ($testSources, $testFrameworks, $testResources,); buildRules = (); dependencies = ($dependency,); name = PhoneTrackerTests; productName = PhoneTrackerTests; productReference = $testProduct; productType = `"com.apple.product-type.bundle.unit-test`";"
Add-Object $project "isa = PBXProject; attributes = { BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; TargetAttributes = { $appTarget = { CreatedOnToolsVersion = 16.0; }; $testTarget = { CreatedOnToolsVersion = 16.0; TestTargetID = $appTarget; }; }; }; buildConfigurationList = $projectConfigList; compatibilityVersion = `"Xcode 14.0`"; developmentRegion = zh_TW; hasScannedForEncodings = 0; knownRegions = (zh_TW, en, Base,); mainGroup = $mainGroup; productRefGroup = $productsGroup; projectDirPath = `"`"; projectRoot = `"`"; targets = ($appTarget, $testTarget,);"
$projectConfigs = @(); $appConfigs = @(); $testConfigs = @()
foreach ($name in @('Debug', 'Release')) {
    $projectConfig = New-Id; $appConfig = New-Id; $testConfig = New-Id
    $debugSettings = if ($name -eq 'Debug') { 'ENABLE_TESTABILITY = YES; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG; DEBUG_INFORMATION_FORMAT = dwarf;' } else { 'SWIFT_COMPILATION_MODE = wholemodule; SWIFT_OPTIMIZATION_LEVEL = "-O"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";' }
    Add-Object $projectConfig "isa = XCBuildConfiguration; buildSettings = { CLANG_ENABLE_MODULES = YES; CLANG_ENABLE_OBJC_ARC = YES; IPHONEOS_DEPLOYMENT_TARGET = 16.0; SDKROOT = iphoneos; SWIFT_VERSION = 5.0; $debugSettings }; name = $name;"
    Add-Object $appConfig 'isa = XCBuildConfiguration; buildSettings = { CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = 1; MARKETING_VERSION = 1.0.0; PRODUCT_BUNDLE_IDENTIFIER = com.jangchyuan.IosPhoneTracker; PRODUCT_NAME = "$(TARGET_NAME)"; INFOPLIST_FILE = PhoneTracker/Info.plist; LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks",); OTHER_LDFLAGS = ("$(inherited)", "-lsqlite3",); SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; TARGETED_DEVICE_FAMILY = "1,2"; SWIFT_EMIT_LOC_STRINGS = YES; }; name = NAME_PLACEHOLDER;'.Replace('NAME_PLACEHOLDER', $name)
    Add-Object $testConfig 'isa = XCBuildConfiguration; buildSettings = { CODE_SIGN_STYLE = Automatic; GENERATE_INFOPLIST_FILE = YES; PRODUCT_BUNDLE_IDENTIFIER = com.jangchyuan.IosPhoneTrackerTests; PRODUCT_NAME = "$(TARGET_NAME)"; BUNDLE_LOADER = "$(TEST_HOST)"; TEST_HOST = "$(BUILT_PRODUCTS_DIR)/PhoneTracker.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/PhoneTracker"; LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks",); OTHER_LDFLAGS = ("$(inherited)", "-lsqlite3",); TARGETED_DEVICE_FAMILY = "1,2"; }; name = NAME_PLACEHOLDER;'.Replace('NAME_PLACEHOLDER', $name)
    $projectConfigs += $projectConfig; $appConfigs += $appConfig; $testConfigs += $testConfig
}
Add-Object $projectConfigList "isa = XCConfigurationList; buildConfigurations = ($($projectConfigs -join ', '),); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;"
Add-Object $appConfigList "isa = XCConfigurationList; buildConfigurations = ($($appConfigs -join ', '),); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;"
Add-Object $testConfigList "isa = XCConfigurationList; buildConfigurations = ($($testConfigs -join ', '),); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;"
$pbx = "// !`$*UTF8*`$!`n{`n archiveVersion = 1; classes = {}; objectVersion = 56; objects = {`n$objects`n }; rootObject = $project;`n}`n"
[IO.File]::WriteAllText((Join-Path $projectDir 'project.pbxproj'), $pbx, [Text.UTF8Encoding]::new($false))
$scheme = @"
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="$appTarget" BuildableName="PhoneTracker.app" BlueprintName="PhoneTracker" ReferencedContainer="container:PhoneTracker.xcodeproj"/>
    </BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>
    <TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="$testTarget" BuildableName="PhoneTrackerTests.xctest" BlueprintName="PhoneTrackerTests" ReferencedContainer="container:PhoneTracker.xcodeproj"/></TestableReference>
  </Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="$appTarget" BuildableName="PhoneTracker.app" BlueprintName="PhoneTracker" ReferencedContainer="container:PhoneTracker.xcodeproj"/></BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="$appTarget" BuildableName="PhoneTracker.app" BlueprintName="PhoneTracker" ReferencedContainer="container:PhoneTracker.xcodeproj"/></BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
"@
[IO.File]::WriteAllText((Join-Path $schemeDir 'PhoneTracker.xcscheme'), $scheme, [Text.UTF8Encoding]::new($false))
Write-Output "Generated PhoneTracker.xcodeproj with app and XCTest targets."
