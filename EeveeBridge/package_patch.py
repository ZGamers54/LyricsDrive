#!/usr/bin/env python3
"""Apply a compiled LyricsDrive patch to the user's local v0.9 IPA."""
import argparse
import os
from pathlib import Path, PurePosixPath
import plistlib
import tempfile
import zipfile


def patch_ipa(source, output, patch_directory):
    source, output, patch_directory = Path(source), Path(output), Path(patch_directory)
    if source.resolve() == output.resolve():
        raise ValueError("Choose a different output; the source IPA is never overwritten.")
    if output.exists():
        raise ValueError("Output already exists. Choose another filename.")
    bridge = patch_directory / "zxPluginsInject.dylib"
    widget = patch_directory / "WidgetExtension.appex"
    if not bridge.is_file() or not (widget / "Info.plist").is_file():
        raise ValueError("Missing compiled bridge or WidgetExtension.appex in the patch.")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with zipfile.ZipFile(source) as original:
            infos = original.infolist()
            for item in infos:
                name = PurePosixPath(item.filename)
                if name.is_absolute() or ".." in name.parts:
                    raise ValueError("Unsafe path in source IPA.")
            app_infos = [item for item in infos if len(PurePosixPath(item.filename).parts) == 3
                         and item.filename.startswith("Payload/")
                         and item.filename.endswith(".app/Info.plist")]
            if len(app_infos) != 1:
                raise ValueError("Expected one host app in the IPA.")
            app_info_name = app_infos[0].filename
            app = str(PurePosixPath(app_info_name).parent) + "/"
            info = plistlib.loads(original.read(app_info_name))
            if info.get("CFBundleExecutable") != "Spotify":
                raise ValueError("This patch requires the standalone EeveeSpotify LyricsDrive v0.9 IPA.")
            preserved_injector = app + "Frameworks/zxPluginsInjectOriginal.dylib"
            if preserved_injector not in original.namelist():
                raise ValueError("Original injector missing. Use your existing LyricsDrive v0.9 IPA.")
            widget_prefix = app + "PlugIns/WidgetExtension.appex/"
            bridge_name = app + "Frameworks/zxPluginsInject.dylib"
            if widget_prefix + "Info.plist" not in original.namelist():
                raise ValueError("LyricsDrive v0.9 widget extension missing.")
            info["NSSupportsLiveActivities"] = True
            info["NSSupportsLiveActivitiesFrequentUpdates"] = True
            modes = list(info.get("UIBackgroundModes", []))
            if "audio" not in modes:
                modes.append("audio")
            info["UIBackgroundModes"] = modes
            info["MinimumOSVersion"] = "26.0"
            info["LyricsDriveVersion"] = "0.11"
            patched_widget_info = plistlib.loads((widget / "Info.plist").read_bytes())
            for key in ("CFBundleShortVersionString", "CFBundleVersion"):
                if key in info:
                    patched_widget_info[key] = info[key]
            patched_widget_info["MinimumOSVersion"] = "26.0"
            patched_widget_info["CFBundleIdentifier"] = info["CFBundleIdentifier"] + ".widgetnowplaying"
            handle, temporary = tempfile.mkstemp(prefix="lyricsdrive-", suffix=".ipa", dir=output.parent)
            os.close(handle)
            with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as result:
                for item in infos:
                    parts = PurePosixPath(item.filename).parts
                    if "_CodeSignature" in parts or parts[-1:] == ("embedded.mobileprovision",):
                        continue
                    if item.filename.startswith(widget_prefix) or item.filename == bridge_name:
                        continue
                    data = plistlib.dumps(info, fmt=plistlib.FMT_BINARY) if item.filename == app_info_name else original.read(item)
                    result.writestr(item, data)
                result.write(bridge, bridge_name)
                for path in sorted(widget.rglob("*")):
                    if not path.is_file() or "_CodeSignature" in path.parts or path.name == "embedded.mobileprovision":
                        continue
                    relative = path.relative_to(widget).as_posix()
                    data = plistlib.dumps(patched_widget_info, fmt=plistlib.FMT_BINARY) if relative == "Info.plist" else path.read_bytes()
                    entry = zipfile.ZipInfo(widget_prefix + relative)
                    entry.create_system = 3
                    executable = relative == patched_widget_info.get("CFBundleExecutable")
                    entry.external_attr = (0o100755 if executable else 0o100644) << 16
                    entry.compress_type = zipfile.ZIP_DEFLATED
                    result.writestr(entry, data)
                commit = patch_directory / "SOURCE_COMMIT.txt"
                if commit.is_file():
                    result.writestr(app + "LyricsDrive_SOURCE_COMMIT.txt", commit.read_bytes())
        os.replace(temporary, output)
        temporary = None
        return output
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_ipa", type=Path)
    parser.add_argument("output_ipa", type=Path)
    parser.add_argument("--patch", type=Path, default=Path(__file__).resolve().parent)
    args = parser.parse_args()
    path = patch_ipa(args.source_ipa, args.output_ipa, args.patch)
    print(f"Created {path}. Sign/install with the same tool used for v0.9; keep the widget extension.")


if __name__ == "__main__":
    main()
