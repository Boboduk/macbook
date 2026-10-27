#!/usr/bin/env python3
"""Generates AlcoveInspired.xcodeproj deterministically.

The project uses Xcode 16 "synchronized folders" (PBXFileSystemSynchronizedRootGroup):
every file inside AlcoveInspired/ is part of the app target automatically, so
the project file never needs to list individual sources. Re-run this script
only when build settings change:

    python3 Scripts/generate_xcodeproj.py
"""

import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = "AlcoveInspired"
BUNDLE_ID = "io.github.boboduk.AlcoveInspired"
MARKETING_VERSION = "1.0.0"
BUILD_NUMBER = "1"
DEPLOYMENT_TARGET = "15.0"
CORE_PACKAGE_PATH = "Packages/IslandCore"


def oid(name: str) -> str:
    """Stable 24-hex-digit object identifier."""
    return hashlib.md5(f"{PROJECT}:{name}".encode()).hexdigest()[:24].upper()


IDS = {name: oid(name) for name in [
    "project", "mainGroup", "productsGroup", "configGroup",
    "appProduct", "infoPlistRef", "entitlementsRef", "readmeRef",
    "syncAppGroup", "appTarget",
    "sourcesPhase", "frameworksPhase", "resourcesPhase",
    "projectConfigList", "projectDebug", "projectRelease",
    "targetConfigList", "targetDebug", "targetRelease",
    "corePackageRef", "coreProductDep", "coreBuildFile",
]}


def settings_block(settings: dict, indent: str) -> str:
    lines = []
    for key in sorted(settings):
        value = settings[key]
        if isinstance(value, list):
            items = "".join(f"{indent}\t\t{quote(item)},\n" for item in value)
            lines.append(f"{indent}\t{key} = (\n{items}{indent}\t);\n")
        else:
            lines.append(f"{indent}\t{key} = {quote(value)};\n")
    return "".join(lines)


def quote(value) -> str:
    value = str(value)
    safe = all(ch.isalnum() or ch in "._/-" for ch in value) and value != ""
    if safe and not value.startswith("-"):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


PROJECT_COMMON = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
    "CLANG_ANALYZER_NONNULL": "YES",
    "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
    "COPY_PHASE_STRIP": "NO",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
    "GCC_WARN_UNUSED_VARIABLE": "YES",
    "MACOSX_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
    "MTL_FAST_MATH": "YES",
    "SDKROOT": "macosx",
    "SWIFT_VERSION": "5.0",
}

PROJECT_DEBUG = {
    **PROJECT_COMMON,
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_DYNAMIC_NO_PIC": "NO",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
    "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
}

PROJECT_RELEASE = {
    **PROJECT_COMMON,
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "ENABLE_NS_ASSERTIONS": "NO",
    "MTL_ENABLE_DEBUG_INFO": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
}

TARGET_COMMON = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    # Ad-hoc signing ("Sign to Run Locally") so the project builds without an
    # Apple Developer account. Set DEVELOPMENT_TEAM + CODE_SIGN_STYLE=Automatic
    # to keep privacy permissions stable across rebuilds.
    "CODE_SIGN_ENTITLEMENTS": "Config/AlcoveInspired.entitlements",
    "CODE_SIGN_IDENTITY": "-",
    "CODE_SIGN_STYLE": "Manual",
    "COMBINE_HIDPI_IMAGES": "YES",
    "CURRENT_PROJECT_VERSION": BUILD_NUMBER,
    "DEVELOPMENT_TEAM": "",
    "ENABLE_HARDENED_RUNTIME": "YES",
    "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": "Config/Info.plist",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
    "MACOSX_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
    "MARKETING_VERSION": MARKETING_VERSION,
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "SWIFT_VERSION": "5.0",
}


def build_configuration(key: str, name: str, settings: dict) -> str:
    return (
        f"\t\t{IDS[key]} /* {name} */ = {{\n"
        f"\t\t\tisa = XCBuildConfiguration;\n"
        f"\t\t\tbuildSettings = {{\n"
        f"{settings_block(settings, chr(9) * 3)}"
        f"\t\t\t}};\n"
        f"\t\t\tname = {name};\n"
        f"\t\t}};\n"
    )


def pbxproj() -> str:
    i = IDS
    return f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 77;
	objects = {{

/* Begin PBXBuildFile section */
		{i['coreBuildFile']} /* IslandCore in Frameworks */ = {{isa = PBXBuildFile; productRef = {i['coreProductDep']} /* IslandCore */; }};
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		{i['appProduct']} /* {PROJECT}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {PROJECT}.app; sourceTree = BUILT_PRODUCTS_DIR; }};
		{i['entitlementsRef']} /* {PROJECT}.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = {PROJECT}.entitlements; sourceTree = "<group>"; }};
		{i['infoPlistRef']} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
		{i['readmeRef']} /* README.md */ = {{isa = PBXFileReference; lastKnownFileType = net.daringfireball.markdown; path = README.md; sourceTree = "<group>"; }};
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		{i['syncAppGroup']} /* {PROJECT} */ = {{
			isa = PBXFileSystemSynchronizedRootGroup;
			path = {PROJECT};
			sourceTree = "<group>";
		}};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
		{i['frameworksPhase']} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{i['coreBuildFile']} /* IslandCore in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{i['mainGroup']} = {{
			isa = PBXGroup;
			children = (
				{i['readmeRef']} /* README.md */,
				{i['syncAppGroup']} /* {PROJECT} */,
				{i['configGroup']} /* Config */,
				{i['productsGroup']} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{i['configGroup']} /* Config */ = {{
			isa = PBXGroup;
			children = (
				{i['infoPlistRef']} /* Info.plist */,
				{i['entitlementsRef']} /* {PROJECT}.entitlements */,
			);
			path = Config;
			sourceTree = "<group>";
		}};
		{i['productsGroup']} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{i['appProduct']} /* {PROJECT}.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{i['appTarget']} /* {PROJECT} */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {i['targetConfigList']} /* Build configuration list for PBXNativeTarget "{PROJECT}" */;
			buildPhases = (
				{i['sourcesPhase']} /* Sources */,
				{i['frameworksPhase']} /* Frameworks */,
				{i['resourcesPhase']} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				{i['syncAppGroup']} /* {PROJECT} */,
			);
			name = {PROJECT};
			packageProductDependencies = (
				{i['coreProductDep']} /* IslandCore */,
			);
			productName = {PROJECT};
			productReference = {i['appProduct']} /* {PROJECT}.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{i['project']} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1600;
				LastUpgradeCheck = 1600;
				TargetAttributes = {{
					{i['appTarget']} = {{
						CreatedOnToolsVersion = 16.0;
					}};
				}};
			}};
			buildConfigurationList = {i['projectConfigList']} /* Build configuration list for PBXProject "{PROJECT}" */;
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
				ru,
			);
			mainGroup = {i['mainGroup']};
			minimizedProjectReferenceProxies = 1;
			packageReferences = (
				{i['corePackageRef']} /* XCLocalSwiftPackageReference "{CORE_PACKAGE_PATH}" */,
			);
			preferredProjectObjectVersion = 77;
			productRefGroup = {i['productsGroup']} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{i['appTarget']} /* {PROJECT} */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{i['resourcesPhase']} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{i['sourcesPhase']} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
{build_configuration('projectDebug', 'Debug', PROJECT_DEBUG)}{build_configuration('projectRelease', 'Release', PROJECT_RELEASE)}{build_configuration('targetDebug', 'Debug', TARGET_COMMON)}{build_configuration('targetRelease', 'Release', TARGET_COMMON)}/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{i['projectConfigList']} /* Build configuration list for PBXProject "{PROJECT}" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{i['projectDebug']} /* Debug */,
				{i['projectRelease']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{i['targetConfigList']} /* Build configuration list for PBXNativeTarget "{PROJECT}" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{i['targetDebug']} /* Debug */,
				{i['targetRelease']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
		{i['corePackageRef']} /* XCLocalSwiftPackageReference "{CORE_PACKAGE_PATH}" */ = {{
			isa = XCLocalSwiftPackageReference;
			relativePath = {CORE_PACKAGE_PATH};
		}};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		{i['coreProductDep']} /* IslandCore */ = {{
			isa = XCSwiftPackageProductDependency;
			productName = IslandCore;
		}};
/* End XCSwiftPackageProductDependency section */
	}};
	rootObject = {i['project']} /* Project object */;
}}
"""


def scheme() -> str:
    app_ref = f"""            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{IDS['appTarget']}"
               BuildableName = "{PROJECT}.app"
               BlueprintName = "{PROJECT}"
               ReferencedContainer = "container:{PROJECT}.xcodeproj">
            </BuildableReference>"""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
{app_ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "IslandCoreTests"
               BuildableName = "IslandCoreTests"
               BlueprintName = "IslandCoreTests"
               ReferencedContainer = "container:{CORE_PACKAGE_PATH}">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
{app_ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
{app_ref}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


def main() -> None:
    project_dir = os.path.join(ROOT, f"{PROJECT}.xcodeproj")
    scheme_dir = os.path.join(project_dir, "xcshareddata", "xcschemes")
    os.makedirs(scheme_dir, exist_ok=True)
    with open(os.path.join(project_dir, "project.pbxproj"), "w") as handle:
        handle.write(pbxproj())
    with open(os.path.join(scheme_dir, f"{PROJECT}.xcscheme"), "w") as handle:
        handle.write(scheme())
    workspace_dir = os.path.join(project_dir, "project.xcworkspace")
    os.makedirs(workspace_dir, exist_ok=True)
    with open(os.path.join(workspace_dir, "contents.xcworkspacedata"), "w") as handle:
        handle.write(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<Workspace\n   version = "1.0">\n'
            '   <FileRef\n      location = "self:">\n   </FileRef>\n'
            '</Workspace>\n'
        )
    print(f"Generated {project_dir}")


if __name__ == "__main__":
    main()
