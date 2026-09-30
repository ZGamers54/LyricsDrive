import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("package_patch", Path(__file__).resolve().parents[1] / "package_patch.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PackagingTests(unittest.TestCase):
    def test_existing_ipa_is_preserved_and_patch_is_complete(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            patch = root / "patch"
            widget = patch / "WidgetExtension.appex"
            widget.mkdir(parents=True)
            (patch / "zxPluginsInject.dylib").write_bytes(b"new bridge")
            (patch / "SOURCE_COMMIT.txt").write_text("tested commit\n")
            (widget / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "WidgetExtension"}))
            (widget / "WidgetExtension").write_bytes(b"new widget")
            source, output = root / "v09.ipa", root / "v011.ipa"
            app = "Payload/Spotify.app/"
            host = {"CFBundleExecutable": "Spotify", "CFBundleIdentifier": "com.spotify.client",
                    "CFBundleVersion": "9098", "CFBundleShortVersionString": "9.0.98", "UIBackgroundModes": ["audio"]}
            with zipfile.ZipFile(source, "w") as bundle:
                bundle.writestr(app + "Info.plist", plistlib.dumps(host))
                bundle.writestr(app + "Spotify", b"unchanged Spotify")
                bundle.writestr(app + "Frameworks/zxPluginsInjectOriginal.dylib", b"original injector")
                bundle.writestr(app + "Frameworks/zxPluginsInject.dylib", b"old bridge")
                bundle.writestr(app + "PlugIns/WidgetExtension.appex/Info.plist", plistlib.dumps({}))
                bundle.writestr(app + "PlugIns/WidgetExtension.appex/old-resource", b"obsolete")
                bundle.writestr(app + "_CodeSignature/CodeResources", b"invalid signature")
            before = source.read_bytes()
            module.patch_ipa(source, output, patch)
            self.assertEqual(source.read_bytes(), before)
            with zipfile.ZipFile(output) as bundle:
                self.assertEqual(bundle.read(app + "Spotify"), b"unchanged Spotify")
                self.assertEqual(bundle.read(app + "Frameworks/zxPluginsInjectOriginal.dylib"), b"original injector")
                self.assertEqual(bundle.read(app + "Frameworks/zxPluginsInject.dylib"), b"new bridge")
                self.assertEqual(bundle.read(app + "PlugIns/WidgetExtension.appex/WidgetExtension"), b"new widget")
                self.assertEqual(bundle.getinfo(app + "PlugIns/WidgetExtension.appex/WidgetExtension").external_attr >> 16,
                                 0o100755)
                self.assertNotIn(app + "PlugIns/WidgetExtension.appex/old-resource", bundle.namelist())
                self.assertNotIn(app + "_CodeSignature/CodeResources", bundle.namelist())
                host_info = plistlib.loads(bundle.read(app + "Info.plist"))
                widget_info = plistlib.loads(bundle.read(app + "PlugIns/WidgetExtension.appex/Info.plist"))
                self.assertEqual(host_info["LyricsDriveVersion"], "0.11")
                self.assertTrue(host_info["NSSupportsLiveActivities"])
                self.assertEqual(widget_info["CFBundleVersion"], host_info["CFBundleVersion"])
                self.assertEqual(widget_info["CFBundleIdentifier"], "com.spotify.client.widgetnowplaying")
            with self.assertRaises(ValueError):
                module.patch_ipa(source, source, patch)
            with self.assertRaises(ValueError):
                module.patch_ipa(source, output, patch)


if __name__ == "__main__":
    unittest.main()
