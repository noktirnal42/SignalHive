#!/usr/bin/env python3
"""Registers new Swift files under App/ in the committed Xcode project.

`project.yml` is the source of truth and `xcodegen generate` (which build_and_run.sh runs when XcodeGen is installed)
rebuilds the project from it. This script is for people without XcodeGen: it adds any App/**/*.swift file that the
committed SignalHive.xcodeproj does not know yet, the way XcodeGen would (a file reference, a build file in every target
that compiles the folder, and membership of the matching group). It changes nothing that is already registered, so it is
safe to run repeatedly.

Usage: script/register_app_sources.py [--check]      (--check lists missing files and exits 1 if there are any)
"""
import hashlib
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
PROJECT = os.path.join(ROOT, "SignalHive.xcodeproj", "project.pbxproj")
APP = os.path.join(ROOT, "App")

# Which App/ subfolders each target compiles (from project.yml), identified by a file that only that set contains.
TARGET_SOURCES = {
    "macOS": ["Shared", "macOS"],
    "MenuBar": ["Shared", "MenuBar"],
    "iOS": ["Shared", "iOS"],
}


def ident(*parts):
    return hashlib.md5(":".join(parts).encode()).hexdigest()[:24].upper()


def swift_files():
    found = []
    for base, _, names in os.walk(APP):
        for name in names:
            if name.endswith(".swift"):
                found.append(os.path.relpath(os.path.join(base, name), APP))
    return sorted(found)


def main():
    check_only = "--check" in sys.argv
    text = open(PROJECT).read()

    registered = set(re.findall(r"path = ([^;]+\.swift); sourceTree", text))
    # A file name can occur in more than one folder, so registration is judged by (folder, name) through the group tree.
    groups = {}
    for match in re.finditer(r"\t\t([0-9A-F]{24}) /\* ([^*]+) \*/ = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n(.*?)\t\t\t\);\n(.*?)\t\t\};", text, re.S):
        gid, name, children, rest = match.groups()
        path = re.search(r"path = ([^;]+);", rest)
        groups[gid] = {"name": name, "path": path.group(1) if path else None,
                       "children": re.findall(r"([0-9A-F]{24}) /\*", children)}
    file_refs = {}
    for match in re.finditer(r"\t\t([0-9A-F]{24}) /\* ([^*]+) \*/ = \{isa = PBXFileReference;[^}]*path = ([^;]+);", text):
        file_refs[match.group(1)] = match.group(3)

    def group_path(gid, trail):
        """Folder (relative to App) that a group stands for, from the top down."""
        return trail

    # Walk from the root group to learn the folder of every group.
    parent_of = {}
    for gid, group in groups.items():
        for child in group["children"]:
            parent_of[child] = gid
    folder_of = {}

    def folder(gid):
        if gid in folder_of:
            return folder_of[gid]
        group = groups[gid]
        parent = parent_of.get(gid)
        base = folder(parent) if parent in groups else ""
        result = os.path.join(base, group["path"]) if group["path"] else base
        folder_of[gid] = result
        return result

    known = set()
    for gid, group in groups.items():
        base = folder(gid)
        for child in group["children"]:
            if child in file_refs and file_refs[child].endswith(".swift"):
                known.add(os.path.join(base, file_refs[child]))
    # Folder names in the tree start at the project root, so paths look like "App/Shared/Views/X.swift".
    known = {os.path.relpath(path, "App") if path.startswith("App") else path for path in known}

    missing = [path for path in swift_files() if path not in known]
    if not missing:
        print("every App/**/*.swift file is already registered")
        return 0
    print("not registered:", *missing, sep="\n  ")
    if check_only:
        return 1

    # The App group and the target build phases.
    app_gid = next(gid for gid, group in groups.items() if group["path"] == "App")
    phases = []
    for match in re.finditer(r"isa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = \d+;\n\t\t\tfiles = \(\n(.*?)\t\t\t\);", text, re.S):
        phases.append(match)
    if len(phases) != 3:
        sys.exit(f"expected 3 Sources phases, found {len(phases)}; not touching the project")

    def phase_for(target):
        """Which phase belongs to a target: the one that already compiles that target's platform file."""
        marker = {"macOS": "MacPlatform.swift", "MenuBar": "MenuBarApp.swift", "iOS": "IOSPlatform.swift"}[target]
        for match in phases:
            if marker in match.group(1):
                return match
        sys.exit(f"no Sources phase compiles {marker}")

    build_lines = []
    ref_lines = []
    group_blocks = []
    new_children = {}          # gid -> [child lines]
    phase_additions = {target: [] for target in TARGET_SOURCES}

    def ensure_group(folder_path):
        """The group id for App/<folder_path>, creating it (and parents) when it does not exist yet."""
        parts = folder_path.split(os.sep)
        gid = app_gid
        walked = ""
        for part in parts:
            walked = os.path.join(walked, part)
            existing = next((c for c in groups[gid]["children"] if c in groups and groups[c]["path"] == part), None)
            if existing is None:
                existing = ident("group", walked)
                if existing not in groups:
                    groups[existing] = {"name": part, "path": part, "children": []}
                    group_blocks.append(existing)
                groups[gid]["children"].append(existing)
                new_children.setdefault(gid, []).append(f"\t\t\t\t{existing} /* {part} */,\n")
            gid = existing
        return gid

    for path in missing:
        directory, name = os.path.split(path)
        top = directory.split(os.sep)[0] if directory else ""
        gid = ensure_group(directory) if directory else app_gid
        ref = ident("ref", path)
        ref_lines.append(f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};\n")
        new_children.setdefault(gid, []).append(f"\t\t\t\t{ref} /* {name} */,\n")
        groups[gid]["children"].append(ref)
        for target, folders in TARGET_SOURCES.items():
            if top in folders:
                build = ident("build", target, path)
                build_lines.append(f"\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};\n")
                phase_additions[target].append(f"\t\t\t\t{build} /* {name} in Sources */,\n")

    # Apply the edits. Later positions first, so earlier offsets stay valid.
    edits = []
    end = text.index("/* End PBXBuildFile section */")
    edits.append((end, "".join(sorted(build_lines))))
    end = text.index("/* End PBXFileReference section */")
    edits.append((end, "".join(sorted(ref_lines))))
    for gid, lines in new_children.items():
        if gid in [g for g in group_blocks]:
            continue
        block = re.search(rf"\t\t{gid} /\* [^*]+ \*/ = \{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n(.*?)\t\t\t\);", text, re.S)
        if block:
            edits.append((block.end(1), "".join(lines)))
    for target, lines in phase_additions.items():
        if lines:
            edits.append((phase_for(target).end(1), "".join(sorted(lines))))
    group_text = ""
    for gid in group_blocks:
        group = groups[gid]
        kids = "".join(new_children.get(gid, []))
        group_text += (f"\t\t{gid} /* {group['name']} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{kids}\t\t\t);\n"
                       f"\t\t\tpath = {group['path']};\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
    if group_text:
        edits.append((text.index("/* End PBXGroup section */"), group_text))

    for position, addition in sorted(edits, key=lambda e: -e[0]):
        text = text[:position] + addition + text[position:]
    open(PROJECT, "w").write(text)
    print(f"registered {len(missing)} file(s) in {os.path.relpath(PROJECT, ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
