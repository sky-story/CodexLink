"""Isolated installer safety tests. No Xcode, phone, home state or running services."""
import argparse
import datetime as dt
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock
from contextlib import redirect_stdout


spec = importlib.util.spec_from_file_location("install_iphone", Path(__file__).parents[1] / "install-iphone.py")
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)
TEAM = "TESTTEAM01"
BUNDLE = "dev.test.codexlink"
DEVICE = {"identifier": "test-device", "hardwareProperties": {"deviceType": "iPhone", "udid": "test-udid"},
          "connectionProperties": {"tunnelState": "connected"},
          "deviceProperties": {"developerModeStatus": "enabled", "name": "Test iPhone"}}


class FakeInstaller(tool.Installer):
    def __init__(self, root, run_dir, state_dir, args):
        super().__init__(root, run_dir, state_dir, args)
        self.calls = []
        self.fail = None
        self.during_build = None
        self.during_backup = None
        self.app = self.derived / "Build/Products/Debug-iphoneos/CodexMobile.app"
        self.version, self.build = "1.4.1", "114"
        self.devices = [DEVICE]
        self.locked = False
        self.install_lock_checks = []
        self.app_exists = True
        self.data_changed = False
        self.profile = {"TeamIdentifier": [TEAM], "ProvisionedDevices": ["test-udid"],
                        "CreationDate": dt.datetime.now(tool.UTC) - dt.timedelta(minutes=5),
                        "ExpirationDate": dt.datetime.now(tool.UTC) + dt.timedelta(days=6),
                        "Entitlements": {"application-identifier": TEAM + ".*"}}
        self.entitlements = {"application-identifier": TEAM + "." + BUNDLE,
                             "com.apple.developer.team-identifier": TEAM}
        self.info = {"CFBundleIdentifier": BUNDLE, "CFBundleShortVersionString": self.version,
                     "CFBundleVersion": self.build, "CFBundleExecutable": "CodexMobile"}

    def run(self, command, name, timeout=120):
        self.calls.append(command)
        if self.fail == name:
            raise tool.InstallError("simulated " + name)
        if command[0] == "xcodebuild" and "-showBuildSettings" in command:
            return json.dumps([{"target": "CodexMobile", "buildSettings": {
                "DEVELOPMENT_TEAM": TEAM, "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE,
                "MARKETING_VERSION": self.version, "CURRENT_PROJECT_VERSION": self.build,
                "TARGET_BUILD_DIR": str(self.app.parent), "FULL_PRODUCT_NAME": self.app.name}}]).encode()
        if command[0] == "xcodebuild":
            self.built_source = (self.source / "CodexMobile/App.swift").read_text()
            self.built_private = (self.source / "CodexMobile/BuildSupport/PrivateOverrides.xcconfig").read_text()
            self.app.mkdir(parents=True)
            (self.app / "Info.plist").write_bytes(plistlib.dumps(self.info))
            (self.app / "CodexMobile").write_bytes(self.built_source.encode())
            if self.during_build:
                self.during_build()
            return b"BUILD SUCCEEDED"
        if command[0] == "security":
            profile = dict(self.profile)
            profile["CreationDate"] = profile["CreationDate"].replace(tzinfo=None)
            profile["ExpirationDate"] = profile["ExpirationDate"].replace(tzinfo=None)
            return plistlib.dumps(profile)
        if "--entitlements" in command:
            return plistlib.dumps(self.entitlements)
        return b""

    def device_call(self, arguments, name, timeout=30):
        self.calls.append(["devicectl", *arguments])
        if self.fail == name:
            raise tool.InstallError("simulated " + name)
        if name == "devices":
            return {"devices": self.devices}
        if name.startswith("lock-"):
            if name.startswith("lock-before-install") and self.install_lock_checks:
                return {"passcodeRequired": self.install_lock_checks.pop(0)}
            return {"passcodeRequired": self.locked}
        if name.startswith("app-"):
            return {"apps": [{"bundleIdentifier": BUNDLE, "version": "1.4.1", "bundleVersion": "114",
                              "builtByDeveloper": True}] if self.app_exists else []}
        if name.startswith("backup-"):
            dest = Path(arguments[arguments.index("--destination") + 1])
            (dest / "Application Support" / BUNDLE).mkdir(parents=True)
            (dest / "Application Support" / BUNDLE / "history-v99.bin").write_bytes(
                b"changed" if self.data_changed and name == "backup-after" else b"encrypted-history")
            (dest / "Preferences").mkdir()
            (dest / "Preferences" / "preferences.plist").write_bytes(b"preferences")
            (dest / "Caches").mkdir()
            (dest / "Caches" / "temporary").write_text(name)
            if name == "backup-before" and self.during_backup:
                self.during_backup()
        return {}


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "project with spaces"
        self.root.mkdir()
        self.git("init", "-q")
        (self.root / ".gitignore").write_text(".build/\nCodexMobile/BuildSupport/PrivateOverrides.xcconfig\n")
        (self.root / tool.PROJECT).mkdir(parents=True)
        (self.root / tool.PROJECT / "project.pbxproj").write_text("fixture-project")
        (self.root / tool.PROJECT / "Package.resolved").write_text("pinned dependency revision")
        (self.root / "CodexMobile/BuildSupport").mkdir()
        self.swift = self.root / "CodexMobile/App.swift"
        self.swift.write_text("old committed source")
        self.git("add", ".")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false",
                 "commit", "-qm", "fixture")
        (self.root / "CodexMobile/BuildSupport/PrivateOverrides.xcconfig").write_text("private setting")
        self.swift.write_text("latest uncommitted source")
        run_dir, state_dir = self.base / "run", self.base / "state"
        run_dir.mkdir()
        state_dir.mkdir()
        self.installer = FakeInstaller(self.root, run_dir, state_dir,
                                       argparse.Namespace(build_only=False, device=None))

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], stderr=subprocess.DEVNULL).decode().strip()

    def execute(self):
        with redirect_stdout(io.StringIO()):
            return self.installer.execute()

    def assert_no_install(self):
        self.assertFalse(any(c[:4] == ["devicectl", "device", "install", "app"] for c in self.installer.calls))

    def test_builds_dirty_local_source_and_private_settings_without_modifying_workspace(self):
        before = tool.source_manifest(self.root)
        self.assertEqual(self.execute(), 0)
        self.assertEqual(self.installer.built_source, "latest uncommitted source")
        self.assertEqual(self.installer.built_private, "private setting")
        self.assertEqual(before, tool.source_manifest(self.root))
        receipt = json.loads((self.installer.run_dir / "receipt.json").read_text())
        self.assertEqual(receipt["status"], "installed_and_launched")
        self.assertEqual(receipt["sourceDigest"], tool.manifest_digest(before))
        self.assertFalse(self.installer.derived.exists())
        self.assertEqual((self.installer.run_dir / "receipt.json").stat().st_mode & 0o777, 0o600)
        install = next(c for c in self.installer.calls if c[:4] == ["devicectl", "device", "install", "app"])
        self.assertIn(str(self.installer.app), install)

    def test_failed_build_never_installs_old_artifact(self):
        old = self.root / ".build/iphone/Build/Products/Debug-iphoneos/CodexMobile.app"
        old.mkdir(parents=True)
        (old / "stale").write_text("old binary")
        self.installer.fail = "编译与签名"
        with self.assertRaises(tool.InstallError):
            self.execute()
        self.assert_no_install()
        self.assertTrue((old / "stale").exists())

    def test_build_success_with_invalid_signature_cannot_install(self):
        self.installer.fail = "校验完整签名"
        with self.assertRaises(tool.InstallError):
            self.execute()
        self.assert_no_install()

    def test_edit_during_build_prevents_install(self):
        self.installer.during_build = lambda: self.swift.write_text("newer edit")
        with self.assertRaisesRegex(tool.InstallError, "源码在本次构建期间发生变化"):
            self.execute()
        self.assert_no_install()

    def test_edit_during_backup_prevents_install(self):
        self.installer.during_backup = lambda: self.swift.write_text("newer edit")
        with self.assertRaisesRegex(tool.InstallError, "源码在本次构建期间发生变化"):
            self.execute()
        self.assert_no_install()

    def test_dependency_lock_mutation_in_snapshot_prevents_install(self):
        self.installer.during_build = lambda: (self.installer.source / tool.PROJECT / "Package.resolved").write_text("mutated")
        with self.assertRaisesRegex(tool.InstallError, "构建改变了源码快照"):
            self.execute()
        self.assert_no_install()

    def test_missing_or_locked_phone_prevents_build(self):
        for devices, locked in (([], False), ([DEVICE, DEVICE], False), ([DEVICE], True)):
            with self.subTest(devices=len(devices), locked=locked):
                self.installer.devices, self.installer.locked = devices, locked
                with self.assertRaises(tool.InstallError):
                    self.execute()
                self.assertFalse(any(c[0] == "xcodebuild" for c in self.installer.calls))

    def test_different_bundle_cannot_create_second_app(self):
        self.installer.app_exists = False
        with self.assertRaisesRegex(tool.InstallError, "只做覆盖安装"):
            self.execute()
        self.assert_no_install()

    def test_phone_can_be_unlocked_after_build_without_rebuilding(self):
        self.installer.install_lock_checks = [True, False]
        with mock.patch.object(tool.time, "sleep"):
            self.assertEqual(self.execute(), 0)
        builds = [c for c in self.installer.calls if c[0] == "xcodebuild" and "build" in c]
        self.assertEqual(len(builds), 1)

    def test_expired_profile_prevents_install(self):
        self.installer.profile["ExpirationDate"] = dt.datetime.now(tool.UTC) - dt.timedelta(minutes=1)
        with self.assertRaisesRegex(tool.InstallError, "签名已到期"):
            self.execute()
        self.assert_no_install()

    def test_wrong_signing_team_prevents_install(self):
        self.installer.entitlements["com.apple.developer.team-identifier"] = "OTHERTEAM1"
        with self.assertRaisesRegex(tool.InstallError, "签名身份不一致"):
            self.execute()
        self.assert_no_install()

    def test_device_not_in_profile_prevents_install(self):
        self.installer.profile["ProvisionedDevices"] = ["another-phone"]
        with self.assertRaisesRegex(tool.InstallError, "不包含这台"):
            self.execute()
        self.assert_no_install()

    def test_older_phone_version_prevents_install(self):
        self.installer.version = "1.3.0"
        with self.assertRaisesRegex(tool.InstallError, "版本旧"):
            self.execute()
        self.assert_no_install()

    def test_backup_failure_prevents_install(self):
        self.installer.fail = "backup-before"
        with self.assertRaises(tool.InstallError):
            self.execute()
        self.assert_no_install()

    def test_data_mismatch_after_install_does_not_restore_or_launch(self):
        self.installer.data_changed = True
        with self.assertRaisesRegex(tool.InstallError, "不会自动还原"):
            self.execute()
        self.assertTrue(self.installer.installed)
        self.assertFalse(any(c[:4] == ["devicectl", "device", "process", "launch"] for c in self.installer.calls))
        self.assertFalse(any(c[:4] == ["devicectl", "device", "copy", "to"] for c in self.installer.calls))

    def test_launch_trust_failure_is_not_reported_as_install_failure(self):
        self.installer.fail = "launch"
        self.assertEqual(self.execute(), 2)
        self.assertTrue(self.installer.installed)
        receipt = json.loads((self.installer.run_dir / "receipt.json").read_text())
        self.assertEqual(receipt["status"], "installed_data_verified")

    def test_build_only_never_contacts_phone_or_updates_install_record(self):
        self.installer.args.build_only = True
        self.assertEqual(self.execute(), 0)
        self.assertFalse(any(c[0] == "devicectl" for c in self.installer.calls))
        self.assertEqual(list(self.installer.state_dir.iterdir()), [])
        self.assertTrue(self.installer.app.exists())

    def test_new_and_deleted_sources_are_detected(self):
        before = tool.source_manifest(self.root)
        (self.root / "CodexMobile/New.swift").write_text("new feature")
        with self.assertRaises(tool.InstallError):
            tool.assert_unchanged(self.root, before)
        (self.root / "CodexMobile/New.swift").unlink()
        self.swift.unlink()
        self.assertNotIn("CodexMobile/App.swift", tool.source_manifest(self.root))
        with self.assertRaises(tool.InstallError):
            tool.assert_unchanged(self.root, before)

    def test_signed_identity_and_keychain_continuity(self):
        identity = {"team": TEAM, "bundle": BUNDLE}
        with self.assertRaises(tool.InstallError):
            tool.validate_identity(identity, {"team": "OTHERTEAM1", "bundle": BUNDLE})
        first = tool.validate_profile(self.installer.profile, self.installer.entitlements,
                                      self.installer.info, identity, "test-udid")
        # An absent explicit keychain group correctly uses application-identifier.
        self.assertEqual(first["keychainGroups"], [TEAM + "." + BUNDLE])
        second = tool.validate_profile(self.installer.profile, self.installer.entitlements,
                                       self.installer.info, identity, "test-udid", first)
        self.assertEqual(first["expires"], second["expires"])
        first["keychainGroups"].append("removed-shared-group")
        with self.assertRaisesRegex(tool.InstallError, "Keychain"):
            tool.validate_profile(self.installer.profile, self.installer.entitlements,
                                  self.installer.info, identity, "test-udid", first)

    def test_old_git_checkout_is_blocked_even_with_same_app_version(self):
        # Same marketing/build numbers cannot conceal a checkout older than the last install.
        old_revision = self.git("rev-parse", "HEAD")
        self.git("add", "CodexMobile/App.swift")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false",
                 "commit", "-qm", "newer code without version bump")
        newer_revision = self.git("rev-parse", "HEAD")
        receipt_path = self.installer.state_dir / (tool.hashlib.sha256(b"test-udid").hexdigest() + ".json")
        tool.write_json(receipt_path, {"revision": newer_revision})
        self.git("checkout", "--detach", old_revision)
        with self.assertRaisesRegex(tool.InstallError, "Git 提交未包含上次安装"):
            self.execute()
        self.assert_no_install()

    def test_profile_expiry_cannot_go_backwards(self):
        identity = {"team": TEAM, "bundle": BUNDLE}
        previous = tool.validate_profile(self.installer.profile, self.installer.entitlements,
                                         self.installer.info, identity, "test-udid")
        self.installer.profile["ExpirationDate"] -= dt.timedelta(days=1)
        with self.assertRaisesRegex(tool.InstallError, "更早到期"):
            tool.validate_profile(self.installer.profile, self.installer.entitlements,
                                  self.installer.info, identity, "test-udid", previous)


if __name__ == "__main__":
    unittest.main()
