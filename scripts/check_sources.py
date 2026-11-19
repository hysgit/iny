"""Static checks only. This script does not replace swift test or xcodebuild."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--swift-parser", action="store_true")
    args = parser.parse_args()
    errors = []
    files = sorted((ROOT / "App").rglob("*.swift")) + sorted((ROOT / "Tests").rglob("*.swift")) + sorted((ROOT / "UITests").rglob("*.swift")) + [ROOT / "Package.swift"]
    for file in files:
        text = file.read_text(encoding="utf-8")
        if "\ufffd" in text:
            errors.append(f"Invalid UTF-8 replacement character in {file.relative_to(ROOT)}")
    info = plistlib.loads((ROOT / "App/Info.plist").read_bytes())
    assert info["CFBundleDisplayName"] == "Iny"
    assert "NSFaceIDUsageDescription" in info
    assert info["CFBundleVersion"] == "$(CURRENT_PROJECT_VERSION)"
    scheme = ET.parse(ROOT / "Iny.xcodeproj/xcshareddata/xcschemes/Iny.xcscheme")
    assert scheme.getroot().tag == "Scheme"
    project = (ROOT / "Iny.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    assert 'PRODUCT_BUNDLE_IDENTIFIER = "net.icycloud.iny"' in project
    referenced = set(re.findall(r'path = "(App/[^\"]+\.swift)";', project))
    actual = {file.relative_to(ROOT).as_posix() for file in (ROOT / "App").rglob("*.swift")}
    if actual != referenced:
        errors.append(f"Xcode source mismatch: {actual ^ referenced}")
    if args.swift_parser:
        sys.path.insert(0, str(ROOT / ".tools/python"))
        from tree_sitter import Language, Parser
        import tree_sitter_swift
        swift = Parser(Language(tree_sitter_swift.language()))
        for file in files:
            content = file.read_bytes()
            root = swift.parse(content).root_node
            stack = [root]
            while stack:
                node = stack.pop()
                if node.type == "ERROR" or node.is_missing:
                    errors.append(f"{file.relative_to(ROOT)}:{node.start_point.row + 1}: {node.type}")
                stack.extend(node.children)
    result = {"kind": "static-source-check", "swiftFiles": len(files), "errors": errors,
              "iosCompilationVerified": False, "swiftTestsExecuted": False}
    destination = ROOT / "analysis/source-checks.json"
    destination.parent.mkdir(exist_ok=True)
    destination.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))
    raise SystemExit(bool(errors))


if __name__ == "__main__":
    main()
