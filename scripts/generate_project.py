#!/usr/bin/env python3
"""Generate a dependency-free Xcode project, without requiring XcodeGen."""
from pathlib import Path
import hashlib

root = Path(__file__).resolve().parents[1] / 'ios'
project = root / 'CodexPocket.xcodeproj'
project.mkdir(exist_ok=True)

def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

objects = []
def obj(name, body):
    objects.append(f'{ident(name)} = {{ {body} }};')
    return ident(name)

def refs(names):
    return '(' + ', '.join(ident(n) for n in names) + ',)'

sources = sorted(p.name for p in (root / 'CodexPocket').glob('*.swift'))
for name in sources:
    obj('file:' + name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>";')
    obj('build:' + name, f'isa = PBXBuildFile; fileRef = {ident("file:" + name)};')
packages = [
    ('Citadel', 'https://github.com/orlandos-nl/Citadel.git', 'kind = revision; revision = ae8562f895de06ccb86fdb1cbb65fd99c8976e12;'),
    ('Crypto', 'https://github.com/apple/swift-crypto.git', 'kind = upToNextMajorVersion; minimumVersion = 3.12.3;'),
    ('NIOSSH', 'https://github.com/Wellz26/swift-nio-ssh.git', 'kind = exactVersion; version = 0.3.4;'),
]
for name, url, requirement in packages:
    obj('package:' + name, f'isa = XCRemoteSwiftPackageReference; repositoryURL = "{url}"; requirement = {{ {requirement} }};')
    obj('product:' + name, f'isa = XCSwiftPackageProductDependency; package = {ident("package:" + name)}; productName = {name};')
    obj('link:' + name, f'isa = PBXBuildFile; productRef = {ident("product:" + name)};')
obj('app', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = CodexPocket.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj('sources', 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ' + refs(['build:' + n for n in sources]) + '; runOnlyForDeploymentPostprocessing = 0;')
obj('frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ' + refs(['link:' + p[0] for p in packages]) + '; runOnlyForDeploymentPostprocessing = 0;')
resourceNames = sorted(p.name for p in (root / 'CodexPocket/Resources').glob('*') if p.is_file())
for name in resourceNames:
    obj('resource:' + name, f'isa = PBXFileReference; lastKnownFileType = image.png; path = Resources/{name}; sourceTree = "<group>";')
    obj('resourceBuild:' + name, f'isa = PBXBuildFile; fileRef = {ident("resource:" + name)};')
obj('resources', 'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ' + refs(['resourceBuild:' + n for n in resourceNames]) + '; runOnlyForDeploymentPostprocessing = 0;')
obj('sourceGroup', 'isa = PBXGroup; children = ' + refs(['file:' + n for n in sources] + ['resource:' + n for n in resourceNames]) + '; path = CodexPocket; sourceTree = "<group>";')
obj('productsGroup', 'isa = PBXGroup; children = ' + refs(['app', 'unitProduct', 'uiProduct']) + '; name = Products; sourceTree = "<group>";')
obj('rootGroup', 'isa = PBXGroup; children = ' + refs(['sourceGroup', 'productsGroup', 'unitGroup', 'uiGroup']) + '; sourceTree = "<group>";')
for config in ('Debug', 'Release'):
    debug = config == 'Debug'
    obj('project:' + config, '''isa = XCBuildConfiguration; buildSettings = {
        SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0;
        CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 5.0; ENABLE_TESTABILITY = YES;
        SWIFT_OPTIMIZATION_LEVEL = "''' + ('-Onone' if debug else '-O') + '''";
        DEBUG_INFORMATION_FORMAT = ''' + ('dwarf' if debug else '"dwarf-with-dsym"') + ''';
        SWIFT_ACTIVE_COMPILATION_CONDITIONS = "''' + ('DEBUG $(inherited)' if debug else '$(inherited)') + '''";
    }; name = ''' + config + ';')
    obj('target:' + config, '''isa = XCBuildConfiguration; buildSettings = {
        PRODUCT_BUNDLE_IDENTIFIER = dev.codexpocket.app;
        PRODUCT_NAME = "$(TARGET_NAME)";
        CODE_SIGN_STYLE = Automatic;
        GENERATE_INFOPLIST_FILE = NO;
        INFOPLIST_FILE = CodexPocket/Info.plist;
        INFOPLIST_KEY_CFBundleDisplayName = "Codex Pocket";
        INFOPLIST_KEY_UILaunchScreen_Generation = YES;
        INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
        TARGETED_DEVICE_FAMILY = "1,2";
        SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
        MARKETING_VERSION = 0.3.0; CURRENT_PROJECT_VERSION = 1;
    }; name = ''' + config + ';')
for scope in ('project', 'target'):
    obj(scope + 'Configs', 'isa = XCConfigurationList; buildConfigurations = ' + refs([scope + ':Debug', scope + ':Release']) + '; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('target', 'isa = PBXNativeTarget; name = CodexPocket; productName = CodexPocket; productType = "com.apple.product-type.application"; productReference = ' + ident('app') + '; buildConfigurationList = ' + ident('targetConfigs') + '; buildPhases = ' + refs(['sources', 'frameworks', 'resources']) + '; buildRules = (); dependencies = (); packageProductDependencies = ' + refs(['product:' + p[0] for p in packages]) + ';')
for scope, folder, testType in [('unit', 'CodexPocketTests', 'unit-test'), ('ui', 'CodexPocketUITests', 'ui-testing')]:
    testSources = sorted((root / folder).glob('*.swift'))
    for file in testSources:
        obj(scope + 'file:' + file.name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {file.name}; sourceTree = "<group>";')
        obj(scope + 'build:' + file.name, f'isa = PBXBuildFile; fileRef = {ident(scope + "file:" + file.name)};')
    obj(scope + 'Group', 'isa = PBXGroup; children = ' + refs([scope + 'file:' + f.name for f in testSources]) + f'; path = {folder}; sourceTree = "<group>";')
    obj(scope + 'Product', f'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = {folder}.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
    obj(scope + 'Sources', 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ' + refs([scope + 'build:' + f.name for f in testSources]) + '; runOnlyForDeploymentPostprocessing = 0;')
    obj(scope + 'Proxy', f'isa = PBXContainerItemProxy; containerPortal = {ident("project")}; proxyType = 1; remoteGlobalIDString = {ident("target")}; remoteInfo = CodexPocket;')
    obj(scope + 'Dependency', f'isa = PBXTargetDependency; target = {ident("target")}; targetProxy = {ident(scope + "Proxy")};')
    for config in ('Debug', 'Release'):
        settings = f'PRODUCT_BUNDLE_IDENTIFIER = dev.codexpocket.{folder}; PRODUCT_NAME = "$(TARGET_NAME)"; GENERATE_INFOPLIST_FILE = YES; CODE_SIGN_STYLE = Automatic;'
        if scope == 'unit':
            settings += ' TEST_HOST = "$(BUILT_PRODUCTS_DIR)/CodexPocket.app/CodexPocket"; BUNDLE_LOADER = "$(TEST_HOST)";'
        else:
            settings += ' TEST_TARGET_NAME = CodexPocket;'
        obj(scope + ':' + config, 'isa = XCBuildConfiguration; buildSettings = {' + settings + '}; name = ' + config + ';')
    obj(scope + 'Configs', 'isa = XCConfigurationList; buildConfigurations = ' + refs([scope + ':Debug', scope + ':Release']) + '; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    obj(scope + 'Target', f'isa = PBXNativeTarget; name = {folder}; productName = {folder}; productType = "com.apple.product-type.bundle.{testType}"; productReference = {ident(scope + "Product")}; buildConfigurationList = {ident(scope + "Configs")}; buildPhases = ' + refs([scope + 'Sources']) + '; buildRules = (); dependencies = ' + refs([scope + 'Dependency']) + ';')
obj('project', 'isa = PBXProject; attributes = { LastUpgradeCheck = 1600; }; buildConfigurationList = ' + ident('projectConfigs') + '; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en, Base, "zh-Hans"); mainGroup = ' + ident('rootGroup') + '; productRefGroup = ' + ident('productsGroup') + '; projectDirPath = ""; projectRoot = ""; targets = ' + refs(['target', 'unitTarget', 'uiTarget']) + '; packageReferences = ' + refs(['package:' + p[0] for p in packages]) + ';')
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + '\n}; rootObject = ' + ident('project') + '; }\n')
scheme = project / 'xcshareddata/xcschemes'
scheme.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident("target")}" BuildableName="CodexPocket.app" BlueprintName="CodexPocket" ReferencedContainer="container:CodexPocket.xcodeproj"/>'
(scheme / 'CodexPocket.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>
<TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('unitTarget')}" BuildableName="CodexPocketTests.xctest" BlueprintName="CodexPocketTests" ReferencedContainer="container:CodexPocket.xcodeproj"/></TestableReference>
<TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('uiTarget')}" BuildableName="CodexPocketUITests.xctest" BlueprintName="CodexPocketUITests" ReferencedContainer="container:CodexPocket.xcodeproj"/></TestableReference>
</Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(project)
