"""Generate the checked-in Xcode project without requiring XcodeGen."""
from hashlib import sha1
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[1]


def ident(value):
    return sha1(value.encode()).hexdigest()[:24].upper()


def quoted(value):
    return json.dumps(str(value), ensure_ascii=False)


def generate():
    objects = []

    def add(key, body):
        objects.append(f"\t\t{ident(key)} = {{ {body} }};")
        return ident(key)

    sources = []
    references = []
    for path in sorted((ROOT / "App").rglob("*.swift")):
        relative = path.relative_to(ROOT).as_posix()
        ref = add(relative, f"isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quoted(relative)}; sourceTree = SOURCE_ROOT;")
        sources.append(add(relative + ":build", f"isa = PBXBuildFile; fileRef = {ref};"))
        references.append(ref)

    info = add("info", 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "App/Info.plist"; sourceTree = SOURCE_ROOT;')
    assets = add("assets", 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = "App/Assets.xcassets"; sourceTree = SOURCE_ROOT;')
    assets_build = add("assetsBuild", f"isa = PBXBuildFile; fileRef = {assets};")
    resource_refs = []
    resource_builds = [assets_build]
    for filename, filetype in [("PrivacyInfo.xcprivacy", "text.xml"), ("ThirdPartyNotices.txt", "text")]:
        ref = add(filename, f"isa = PBXFileReference; lastKnownFileType = {filetype}; path = {quoted('App/' + filename)}; sourceTree = SOURCE_ROOT;")
        resource_refs.append(ref)
        resource_builds.append(add(filename + ":build", f"isa = PBXBuildFile; fileRef = {ref};"))
    product = add("product", 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Iny.app; sourceTree = BUILT_PRODUCTS_DIR;')
    ui_product = add("uiProduct", 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = InyUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
    ui_ref = add("uiFile", 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "UITests/PlaybackUITests.swift"; sourceTree = SOURCE_ROOT;')
    ui_build = add("uiFileBuild", f"isa = PBXBuildFile; fileRef = {ui_ref};")
    products = add("products", f"isa = PBXGroup; children = ({product},{ui_product},); name = Products; sourceTree = \"<group>\";")
    group = add("rootGroup", f"isa = PBXGroup; children = ({','.join(references + resource_refs + [info, assets, ui_ref, products])},); sourceTree = \"<group>\";")
    package = add("smbPackage", 'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/amosavian/AMSMB2.git"; requirement = { kind = exactVersion; version = 3.4.0; };')
    dependency = add("smbProduct", f"isa = XCSwiftPackageProductDependency; package = {package}; productName = AMSMB2;")
    framework = add("smbBuild", f"isa = PBXBuildFile; productRef = {dependency};")
    source_phase = add("sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({','.join(sources)},); runOnlyForDeploymentPostprocessing = 0;")
    frameworks = add("frameworks", f"isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({framework},); runOnlyForDeploymentPostprocessing = 0;")
    resources = add("resources", f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({','.join(resource_builds)},); runOnlyForDeploymentPostprocessing = 0;")

    def configurations(prefix, settings):
        configs = []
        for name in ["Debug", "Release"]:
            specific = dict(settings)
            specific["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone" if name == "Debug" else "-O"
            specific["DEBUG_INFORMATION_FORMAT"] = "dwarf" if name == "Debug" else "dwarf-with-dsym"
            if name == "Debug":
                specific["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
                specific["ENABLE_TESTABILITY"] = "YES"
                specific["ONLY_ACTIVE_ARCH"] = "YES"
            body = " ".join(f"{k} = {quoted(v)};" for k, v in specific.items())
            configs.append(add(prefix + name, f"isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = {name};"))
        return add(prefix + "list", f"isa = XCConfigurationList; buildConfigurations = ({','.join(configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")

    project_config = configurations("projectConfig", {
        "CLANG_ENABLE_MODULES": "YES", "SWIFT_VERSION": "5.0", "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "SDKROOT": "iphoneos", "ENABLE_USER_SCRIPT_SANDBOXING": "NO", "CLANG_ENABLE_OBJC_ARC": "YES",
    })
    target_config = configurations("targetConfig", {
        "PRODUCT_BUNDLE_IDENTIFIER": "net.icycloud.iny", "PRODUCT_NAME": "$(TARGET_NAME)",
        "INFOPLIST_FILE": "App/Info.plist", "CURRENT_PROJECT_VERSION": "1", "MARKETING_VERSION": "0.1.0",
        "TARGETED_DEVICE_FAMILY": "1,2", "CODE_SIGN_STYLE": "Automatic",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks", "SUPPORTS_MACCATALYST": "NO",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    })
    target = add("target", f"isa = PBXNativeTarget; buildConfigurationList = {target_config}; buildPhases = ({source_phase},{frameworks},{resources},); buildRules = (); dependencies = (); name = Iny; packageProductDependencies = ({dependency},); productName = Iny; productReference = {product}; productType = \"com.apple.product-type.application\";")
    ui_config = configurations("uiConfig", {
        "PRODUCT_BUNDLE_IDENTIFIER": "net.icycloud.iny.uitests", "PRODUCT_NAME": "$(TARGET_NAME)",
        "GENERATE_INFOPLIST_FILE": "YES", "TARGETED_DEVICE_FAMILY": "1,2", "TEST_TARGET_NAME": "Iny",
        "CODE_SIGN_STYLE": "Automatic", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @loader_path/Frameworks",
    })
    ui_sources = add("uiSources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({ui_build},); runOnlyForDeploymentPostprocessing = 0;")
    ui_frameworks = add("uiFrameworks", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
    ui_proxy = add("uiProxy", f"isa = PBXContainerItemProxy; containerPortal = {ident('project')}; proxyType = 1; remoteGlobalIDString = {target}; remoteInfo = Iny;")
    ui_dependency = add("uiDependency", f"isa = PBXTargetDependency; target = {target}; targetProxy = {ui_proxy};")
    ui_target = add("uiTarget", f"isa = PBXNativeTarget; buildConfigurationList = {ui_config}; buildPhases = ({ui_sources},{ui_frameworks},); buildRules = (); dependencies = ({ui_dependency},); name = InyUITests; productName = InyUITests; productReference = {ui_product}; productType = \"com.apple.product-type.bundle.ui-testing\";")
    project = add("project", f"isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastSwiftUpdateCheck = 1600; LastUpgradeCheck = 1600; TargetAttributes = {{ {ui_target} = {{ TestTargetID = {target}; }}; }}; }}; buildConfigurationList = {project_config}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = zh_CN; hasScannedForEncodings = 0; knownRegions = (en, zh_CN, Base,); mainGroup = {group}; packageReferences = ({package},); productRefGroup = {products}; projectDirPath = \"\"; projectRoot = \"\"; targets = ({target},{ui_target},);")
    project_dir = ROOT / "Iny.xcodeproj"
    project_dir.mkdir(exist_ok=True)
    text = "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n" + "\n".join(objects) + f"\n\t}};\n\trootObject = {project};\n}}\n"
    (project_dir / "project.pbxproj").write_text(text, encoding="utf-8", newline="\n")
    schemes = project_dir / "xcshareddata/xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Iny.app" BlueprintName="Iny" ReferencedContainer="container:Iny.xcodeproj"/>'
    test_reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ui_target}" BuildableName="InyUITests.xctest" BlueprintName="InyUITests" ReferencedContainer="container:Iny.xcodeproj"/>'
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{test_reference}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
    (schemes / "Iny.xcscheme").write_text(scheme, encoding="utf-8", newline="\n")
    print(f"Generated Iny.xcodeproj with {len(sources)} Swift sources")


if __name__ == "__main__":
    generate()
