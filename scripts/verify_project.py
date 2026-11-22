#!/usr/bin/env python3
"""Validate project structure and optionally Swift grammar without claiming a build.

Run from any directory: python scripts/verify_project.py --require-swift-parser
Install the optional parser locally using requirements-validation.txt.
Xcode compilation, XCTest execution and device testing remain separate Mac steps.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import plistlib
import re
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


class OpenStepParser:
    """Small strict parser for the dictionaries/lists used by an Xcode pbxproj."""

    pattern = re.compile(r'\s+|/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,"/]+', re.S)

    def __init__(self, source: str):
        self.tokens: list[str] = []
        end = 0
        for match in self.pattern.finditer(source):
            if match.start() != end:
                raise ValueError(f"Unrecognized project syntax at byte {end}")
            token = match.group()
            end = match.end()
            if not token.isspace() and not token.startswith(("/*", "//")):
                self.tokens.append(token)
        if end != len(source):
            raise ValueError(f"Unrecognized project syntax at byte {end}")
        self.index = 0

    def take(self, expected: str | None = None) -> str:
        if self.index >= len(self.tokens):
            raise ValueError("Unexpected end of project")
        token = self.tokens[self.index]
        self.index += 1
        if expected is not None and token != expected:
            raise ValueError(f"Expected {expected!r}, found {token!r}")
        return token

    def value(self):
        token = self.take()
        if token == "{":
            result = {}
            while self.tokens[self.index] != "}":
                key = self.take().strip('"')
                if key in result:
                    raise ValueError(f"Duplicate project key {key}")
                self.take("=")
                result[key] = self.value()
                self.take(";")
            self.take("}")
            return result
        if token == "(":
            result = []
            while self.tokens[self.index] != ")":
                result.append(self.value())
                if self.tokens[self.index] != ")":
                    self.take(",")
            self.take(")")
            return result
        if token in "}=;,)":
            raise ValueError(f"Unexpected project token {token}")
        return token.strip('"')

    def parse(self):
        value = self.value()
        if self.index != len(self.tokens):
            raise ValueError("Unexpected tokens after project root")
        return value


def all_values(value):
    if isinstance(value, dict):
        for child in value.values():
            yield from all_values(child)
    elif isinstance(value, list):
        for child in value:
            yield from all_values(child)
    else:
        yield value


def check_structure() -> int:
    project_path = ROOT / "Komiic.xcodeproj/project.pbxproj"
    project = OpenStepParser(project_path.read_text(encoding="utf-8-sig")).parse()
    objects = project["objects"]
    assert objects[project["rootObject"]]["isa"] == "PBXProject"
    for value in all_values(project):
        if isinstance(value, str) and re.fullmatch(r"[A-F0-9]{24}", value):
            assert value in objects, f"Undefined Xcode object {value}"
    targets = {obj["name"]: (key, obj) for key, obj in objects.items() if obj.get("isa") == "PBXNativeTarget"}
    assert set(targets) == {"Komiic", "KomiicTests"}, "App/test targets missing"
    for name, (_, target) in targets.items():
        groups = [objects[key] for key in target["fileSystemSynchronizedGroups"]]
        assert len(groups) == 1 and groups[0]["path"] == name
        assert (ROOT / name).is_dir(), f"Synchronized folder missing: {name}"
        configurations = objects[target["buildConfigurationList"]]["buildConfigurations"]
        assert {objects[key]["name"] for key in configurations} == {"Debug", "Release"}
    app = targets["Komiic"][1]
    for configuration in objects[app["buildConfigurationList"]]["buildConfigurations"]:
        settings = objects[configuration]["buildSettings"]
        assert settings["GENERATE_INFOPLIST_FILE"] == "YES"
        assert settings["INFOPLIST_KEY_UIRequiresFullScreen"] == "NO"
        assert "UIInterfaceOrientationPortraitUpsideDown" in settings["INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad"]
        assert settings["INFOPLIST_KEY_UIFileSharingEnabled"] == "YES"
        assert settings["INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace"] == "YES"
        assert "UIInterfaceOrientationLandscapeLeft" in settings["INFOPLIST_KEY_UISupportedInterfaceOrientations"]
    scheme = ET.parse(ROOT / "Komiic.xcodeproj/xcshareddata/xcschemes/Komiic.xcscheme")
    for reference in scheme.findall(".//BuildableReference"):
        assert reference.attrib["BlueprintIdentifier"] in objects
    assert scheme.find(".//TestableReference") is not None
    sources = sorted((ROOT / "Komiic").rglob("*.swift")) + sorted((ROOT / "KomiicTests").rglob("*.swift"))
    assert sources, "No Swift source files"
    app_sources = list((ROOT / "Komiic").rglob("*.swift"))
    assert sum(len(re.findall(r"@main\b", path.read_text(encoding="utf-8-sig"))) for path in app_sources) == 1, "App must have exactly one entry point"
    for source in sources:
        text = source.read_text(encoding="utf-8-sig")
        assert not re.search(r"^(<<<<<<<|=======|>>>>>>>)", text, re.M), f"Merge marker: {source}"
    for path in (ROOT / "Komiic").rglob("Contents.json"):
        content = json.loads(path.read_text(encoding="utf-8-sig"))
        for image in content.get("images", []):
            if "filename" in image:
                assert (path.parent / image["filename"]).is_file(), f"Missing asset: {image['filename']}"
    for name in ["AppIcon.appiconset", "AccentColor.colorset"]:
        assert list((ROOT / "Komiic").rglob(name)), f"Asset catalog missing {name}"
    privacy = plistlib.loads((ROOT / "Komiic/PrivacyInfo.xcprivacy").read_bytes())
    assert len(privacy["NSPrivacyAccessedAPITypes"]) == 3
    print(f"PASS: Xcode project references, shared scheme, assets, and {len(sources)} source-file entries")
    return len(sources)


def check_swift_grammar(required: bool) -> bool:
    local_packages = ROOT / ".validation-packages"
    if local_packages.is_dir():
        sys.path.insert(0, str(local_packages))
    try:
        from tree_sitter import Language, Parser
        import tree_sitter_swift
    except ImportError:
        if required:
            raise RuntimeError("Swift parser not installed; see scripts/requirements-validation.txt")
        print("SKIP: Swift grammar parser unavailable; structure-only validation")
        return False
    parser = Parser(Language(tree_sitter_swift.language()))
    sources = sorted((ROOT / "Komiic").rglob("*.swift")) + sorted((ROOT / "KomiicTests").rglob("*.swift"))
    failures = []
    for path in sources:
        data = path.read_bytes()
        tree = parser.parse(data)
        if tree.root_node.has_error:
            stack = [tree.root_node]
            while stack:
                node = stack.pop()
                if node.type == "ERROR" or node.is_missing:
                    row, column = node.start_point
                    snippet = data[node.start_byte:node.end_byte].decode("utf-8", errors="replace")[:140]
                    failures.append(f"{path.relative_to(ROOT)}:{row + 1}:{column + 1}: {node.type}: {snippet!r}")
                stack.extend(reversed(node.children))
    if failures:
        raise ValueError("Swift grammar errors:\n" + "\n".join(failures))
    print(f"PASS: Swift grammar parsed {len(sources)} source files without error nodes")
    return True


def main() -> int:
    arguments = argparse.ArgumentParser(description=__doc__)
    arguments.add_argument("--require-swift-parser", action="store_true")
    options = arguments.parse_args()
    try:
        check_structure()
        check_swift_grammar(options.require_swift_parser)
    except (AssertionError, ValueError, RuntimeError, KeyError, OSError, IndexError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("NOT RUN: Xcode compiler, XCTest runner, iOS simulator, or device verification (requires macOS/Xcode)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
