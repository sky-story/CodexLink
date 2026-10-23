#!/usr/bin/env python3
"""Build the current working tree and overwrite an existing iPhone installation.

No git checkout/pull/reset, uninstall, pairing reset, or Mac service management.
The executable app is always produced in this invocation's fresh build directory.
"""
import argparse
import datetime as dt
import fcntl
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
PROJECT = Path("CodexMobile/CodexMobile.xcodeproj")
SKIP_DIRS = {".git", ".build", "build", "DerivedData", "xcuserdata", "__pycache__"}
UTC = dt.timezone.utc


class InstallError(Exception):
    pass


def say(message):
    print(message, flush=True)


def git(root, *args):
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True)
    if result.returncode:
        raise InstallError("无法读取 Git 项目。请从项目内运行此工具，勿单独复制启动器。")
    return result.stdout.decode("utf-8")


def file_hash(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_manifest(root):
    # Include uncommitted/untracked source AND ignored iOS private build settings.
    names = set(git(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard").split("\0"))
    for directory, dirs, files in os.walk(root / "CodexMobile"):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS and not d.endswith(".xcuserdatad"))
        if any((Path(directory) / d).is_symlink() for d in dirs):
            raise InstallError("iOS 工程含目录符号链接，无法完整核对构建输入；请用 Xcode 检查。")
        names.update(str((Path(directory) / name).relative_to(root)) for name in files)
    manifest = {}
    for name in sorted(names - {""}):
        path = Path(name)
        if path.is_absolute() or ".." in path.parts:
            raise InstallError("源码路径超出项目目录。")
        if any(p in SKIP_DIRS or p.endswith(".xcuserdatad") for p in path.parts) or path.name == ".DS_Store":
            continue
        source = root / path
        if source.is_symlink():
            raise InstallError("源码包含符号链接，无法完整核对构建输入：" + name)
        if source.is_file():  # A tracked file deleted locally must stay deleted.
            manifest[name] = file_hash(source)
    return manifest


def manifest_digest(manifest):
    return hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest()


def assert_unchanged(root, expected):
    actual = source_manifest(root)
    changed = sorted(k for k in expected.keys() | actual.keys() if expected.get(k) != actual.get(k))
    if changed:
        raise InstallError("源码在本次构建期间发生变化，已停止安装。保存修改后重新运行。变化文件："
                           + ", ".join(changed[:5]))


def snapshot_sources(root, destination, manifest):
    for name, digest in manifest.items():
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / name, target)
        if file_hash(target) != digest:
            raise InstallError("复制时源码发生变化，请保存修改后重新运行：" + name)
    assert_unchanged(root, manifest)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    temporary.chmod(0o600)
    temporary.replace(path)


def read_json(path):
    return json.loads(path.read_text()) if path.exists() else None


def version_tuple(value):
    if not re.fullmatch(r"\d+(?:\.\d+)*", str(value)):
        raise InstallError("无法比较 App 版本号：" + str(value))
    numbers = tuple(int(n) for n in str(value).split("."))
    return numbers + (0,) * max(0, 4 - len(numbers))


def reject_downgrade(candidate, installed):
    version = version_tuple(candidate["version"])
    previous = version_tuple(installed["version"])
    if version < previous or (version == previous and
                             version_tuple(candidate["build"]) < version_tuple(installed["build"])):
        raise InstallError("当前源码的 App 版本比手机或上次安装的版本旧，已阻止覆盖。请使用更新后的项目。")


def validate_identity(candidate, previous):
    if previous and any(candidate[key] != previous[key] for key in ("team", "bundle")):
        raise InstallError("Team 或 Bundle ID 与上次安装不同，已停止，避免生成另一个 App 或丢失配对访问。"
                           "请在 Xcode 恢复原签名设置。")


def select_device(devices, requested=None):
    candidates = [d for d in devices if d.get("hardwareProperties", {}).get("deviceType") == "iPhone"
                  and d.get("connectionProperties", {}).get("tunnelState") in ("connected", "disconnected")]
    if requested:
        candidates = [d for d in candidates if requested in
                      (d.get("identifier"), d.get("hardwareProperties", {}).get("udid"),
                       d.get("deviceProperties", {}).get("name"))]
    if not candidates:
        raise InstallError("未找到可用的 iPhone。请用数据线连接、解锁并信任此 Mac，然后重新运行。")
    if len(candidates) != 1:
        names = ", ".join(d["deviceProperties"].get("name", d["identifier"]) for d in candidates)
        raise InstallError("检测到多台 iPhone（" + names + "）。请只连接目标手机，或用 --device 指定名称/UDID。")
    return candidates[0]


def utc(value):
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)


def validate_profile(profile, entitlements, info, identity, udid=None, previous=None, now=None):
    now = now or dt.datetime.now(UTC)
    app_id = identity["team"] + "." + identity["bundle"]
    if info.get("CFBundleIdentifier") != identity["bundle"]:
        raise InstallError("构建产物的 Bundle ID 与工程设置不同。")
    if (identity["team"] not in profile.get("TeamIdentifier", [])
            or entitlements.get("application-identifier") != app_id
            or entitlements.get("com.apple.developer.team-identifier") != identity["team"]
            or not fnmatch.fnmatchcase(app_id, profile.get("Entitlements", {}).get("application-identifier", ""))):
        raise InstallError("App、描述文件与预期的签名身份不一致，拒绝安装。")
    if udid and udid not in profile.get("ProvisionedDevices", []) and not profile.get("ProvisionsAllDevices"):
        raise InstallError("新签名不包含这台 iPhone；请在 Xcode 中选择手机完成签名设置。")
    expires = utc(profile["ExpirationDate"])
    created = utc(profile["CreationDate"])
    if expires <= now + dt.timedelta(minutes=5) or created > now + dt.timedelta(minutes=5):
        raise InstallError("签名已到期、即将到期或签发时间异常，拒绝安装。请检查 Mac 时间和 Xcode 账号后重试。")
    groups = sorted(entitlements.get("keychain-access-groups", [app_id]))
    if previous:
        if not set(previous.get("keychainGroups", [])).issubset(groups):
            raise InstallError("新版本移除了原 Keychain 访问组，可能无法读取配对；已停止安装。")
        if expires < dt.datetime.fromisoformat(previous["expires"]):
            raise InstallError("新签名比上次安装更早到期，已停止安装。")
    return {**identity, "applicationIdentifier": app_id, "keychainGroups": groups,
            "created": created.isoformat(), "expires": expires.isoformat(),
            "version": str(info["CFBundleShortVersionString"]), "build": str(info["CFBundleVersion"])}


def data_manifest(directory):
    # Cache files may legitimately change during installation; persistent data may not.
    return {str(p.relative_to(directory)): file_hash(p) for p in sorted(directory.rglob("*"))
            if p.is_file() and any(x in p.relative_to(directory).parts
                                   for x in ("Application Support", "Preferences"))}


class Installer:
    def __init__(self, root, run_dir, state_dir, args):
        self.root, self.run_dir, self.state_dir, self.args = root, run_dir, state_dir, args
        self.source = run_dir / "source"
        self.derived = run_dir / "DerivedData"
        self.installed = False
        self.counter = 0

    def run(self, command, name, timeout=120):
        self.counter += 1
        prefix = self.run_dir / ("%02d-%s" % (self.counter, name))
        out_path, err_path = prefix.with_suffix(".stdout.log"), prefix.with_suffix(".stderr.log")
        started = time.monotonic()
        with out_path.open("wb") as stdout, err_path.open("wb") as stderr:
            process = subprocess.Popen(command, cwd=self.source if self.source.exists() else self.root,
                                       stdout=stdout, stderr=stderr, start_new_session=True)
            try:
                while True:
                    try:
                        code = process.wait(timeout=min(20, timeout))
                        break
                    except subprocess.TimeoutExpired:
                        elapsed = int(time.monotonic() - started)
                        if elapsed >= timeout:
                            raise InstallError(name + " 超时，请查看日志后重试。")
                        say("  %s 进行中（%d 秒）…" % (name, elapsed))
            except BaseException:
                # Only our subprocess group, never any existing CLI/Bridge process.
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                raise
        if code:
            raise InstallError("%s 失败（退出码 %s）。日志：%s 和 %s" % (name, code, out_path, err_path))
        return out_path.read_bytes()

    def device_call(self, arguments, name, timeout=30):
        result_path = self.run_dir / (name + ".json")
        self.run(["xcrun", "devicectl", *arguments, "--timeout", str(timeout),
                  "--json-output", str(result_path)], name, timeout + 10)
        result = read_json(result_path)
        if not result or result.get("info", {}).get("outcome") != "success":
            raise InstallError(name + " 未返回成功的设备结果。")
        return result["result"]

    def xcode_command(self):
        return ["xcodebuild", "-project", str(self.source / PROJECT), "-scheme", "CodexMobile",
                "-configuration", "Debug", "-destination", "generic/platform=iOS", "-jobs", "2",
                "-derivedDataPath", str(self.derived),
                "-clonedSourcePackagesDirPath", str(self.root / ".build/iphone-installer/SourcePackages"),
                "-disableAutomaticPackageResolution", "-skipPackageUpdates"]

    def check_unlocked(self, device, name, wait=False):
        deadline = time.monotonic() + 120
        attempt = 0
        while True:
            result = self.device_call(["device", "info", "lockState", "--device", device],
                                      name + ("-%d" % attempt if attempt else ""))
            if result.get("passcodeRequired") is False:
                return
            if result.get("passcodeRequired") is not True or not wait or time.monotonic() >= deadline:
                raise InstallError("iPhone 处于锁定状态或无法确认已解锁。请解锁并保持屏幕亮起，再重新运行。")
            if attempt == 0:
                say("编译已完成，请解锁 iPhone 以继续安装（最多等待 2 分钟，无需重新编译）…")
            time.sleep(3)
            attempt += 1

    def backup_library(self, device, bundle, label):
        destination = self.run_dir / label / "Library"
        destination.parent.mkdir(parents=True)
        self.device_call(["device", "copy", "from", "--device", device, "--source", "Library",
                          "--destination", str(destination), "--domain-type", "appDataContainer",
                          "--domain-identifier", bundle], label, timeout=120)
        if not destination.is_dir():
            raise InstallError("手机 Library 备份未生成，已停止后续操作。")
        return data_manifest(destination)

    def execute(self):
        say("项目：" + str(self.root))
        device = None
        previous = None
        if not self.args.build_only:
            say("[1/6] 检查已连接的 iPhone…")
            devices = self.device_call(["list", "devices"], "devices")["devices"]
            device = select_device(devices, self.args.device)
            if device.get("deviceProperties", {}).get("developerModeStatus") != "enabled":
                raise InstallError("请先在 iPhone 开启开发者模式，并在 Xcode 完成首次安装。")
            device_id = device["identifier"]
            self.check_unlocked(device_id, "lock-before-build")
            udid = device["hardwareProperties"]["udid"]
            receipt_path = self.state_dir / (hashlib.sha256(udid.encode()).hexdigest() + ".json")
            previous = read_json(receipt_path)
            say("手机：" + device["deviceProperties"].get("name", "iPhone"))

        say("[2/6] 复制当前源码，包括未提交修改…")
        manifest = source_manifest(self.root)
        revision = git(self.root, "rev-parse", "HEAD").strip()
        branch = git(self.root, "branch", "--show-current").strip() or "detached HEAD"
        digest = manifest_digest(manifest)
        snapshot_sources(self.root, self.source, manifest)
        provenance = {"sourceRoot": str(self.root), "revision": revision, "branch": branch,
                      "sourceDigest": digest, "sourceFiles": len(manifest),
                      "workingTreeChanged": bool(git(self.root, "status", "--porcelain").strip())}
        write_json(self.run_dir / "source-manifest.json", manifest)
        write_json(self.run_dir / "source.json", provenance)
        say("源码：%s / %s；当前文件摘要 %s（含本地修改）" % (branch, revision[:12], digest[:12]))
        if previous:
            ancestor = subprocess.run(["git", "-C", str(self.root), "merge-base", "--is-ancestor",
                                       previous["revision"], revision], capture_output=True)
            if ancestor.returncode:
                raise InstallError("当前 Git 提交未包含上次安装的提交，已阻止可能的代码回退。请核对项目分支。")

        settings_rows = json.loads(self.run(self.xcode_command() + ["-showBuildSettings", "-json"],
                                           "读取构建设置", timeout=300))
        targets = [r["buildSettings"] for r in settings_rows if r.get("target") == "CodexMobile"]
        if len(targets) != 1:
            raise InstallError("未找到唯一的 CodexMobile 构建目标。")
        settings = targets[0]
        identity = {"team": settings.get("DEVELOPMENT_TEAM", ""),
                    "bundle": settings.get("PRODUCT_BUNDLE_IDENTIFIER", "")}
        if not identity["team"] or not identity["bundle"] or identity["bundle"].startswith("com.example."):
            raise InstallError("尚未配置个人签名；请在 Xcode 选择自己的 Team 和原 App 的 Bundle ID。")
        validate_identity(identity, previous)
        candidate = {"version": settings["MARKETING_VERSION"], "build": settings["CURRENT_PROJECT_VERSION"]}
        if previous:
            reject_downgrade(candidate, previous)
        if device:
            apps = self.device_call(["device", "info", "apps", "--device", device_id,
                                     "--bundle-id", identity["bundle"]], "app-before")["apps"]
            if len(apps) != 1 or not apps[0].get("builtByDeveloper"):
                raise InstallError("手机上没有相同 Bundle ID 的开发版 App。此工具只做覆盖安装；"
                                   "请恢复原签名设置，首次安装请使用 Xcode。")
            reject_downgrade(candidate, {"version": apps[0]["version"], "build": apps[0]["bundleVersion"]})

        say("[3/6] 重新编译并签名（不会复用旧安装包）…")
        say("若 Xcode 提示账号失效，请在 Xcode → Settings → Accounts 重新登录。")
        self.run(self.xcode_command() + ["-allowProvisioningUpdates", "clean", "build"],
                 "编译与签名", timeout=1800)
        assert_unchanged(self.root, manifest)
        # Xcode must not silently update a dependency lockfile or project in the snapshot.
        for name, expected in manifest.items():
            if not (self.source / name).is_file() or file_hash(self.source / name) != expected:
                raise InstallError("构建改变了源码快照，拒绝安装：" + name)
        app = Path(settings["TARGET_BUILD_DIR"]) / settings["FULL_PRODUCT_NAME"]
        if self.derived.resolve() not in app.resolve().parents or not app.is_dir():
            raise InstallError("本次构建未生成预期的新 App，拒绝回退使用旧安装包。")
        self.run(["codesign", "--verify", "--deep", "--strict", str(app)], "校验完整签名")
        profile = plistlib.loads(self.run(["security", "cms", "-D", "-i", str(app / "embedded.mobileprovision")],
                                          "读取描述文件"))
        entitlements = plistlib.loads(self.run(["codesign", "-d", "--entitlements", ":-", str(app)], "读取签名权限"))
        info = plistlib.loads((app / "Info.plist").read_bytes())
        signed = validate_profile(profile, entitlements, info, identity,
                                  device["hardwareProperties"]["udid"] if device else None, previous)
        if signed["version"] != candidate["version"] or signed["build"] != candidate["build"]:
            raise InstallError("实际 App 版本与本次构建设置不一致，拒绝安装。")
        expiry = dt.datetime.fromisoformat(signed["expires"])
        say("App：%s (%s)；签名实际到期：%s" % (signed["version"], signed["build"],
                                                       expiry.astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")))
        if previous and signed["expires"] == previous["expires"]:
            say("Xcode 复用了仍有效的描述文件：此次更新代码，但没有延长签名期限。")
        else:
            say("有效期以 Apple 描述文件为准；重装不代表从今天重新获得 7 天。")
        receipt = {**provenance, **signed, "binarySHA256": file_hash(app / info["CFBundleExecutable"]),
                   "runDirectory": str(self.run_dir), "status": "built"}
        write_json(self.run_dir / "receipt.json", receipt)
        if self.args.build_only:
            say("仅构建验证完成，尚未安装到手机。产物：" + str(app))
            return 0

        say("[4/6] 再次检查手机，并备份 Library 中的历史与设置…")
        self.check_unlocked(device_id, "lock-before-install", wait=True)
        before = self.backup_library(device_id, identity["bundle"], "backup-before")
        write_json(self.run_dir / "data-before.json", before)
        assert_unchanged(self.root, manifest)
        if git(self.root, "rev-parse", "HEAD").strip() != revision:
            raise InstallError("构建期间 Git 提交发生变化，请重新运行。")
        say("[5/6] 覆盖安装同一个 App，保留容器和 Keychain…")
        self.device_call(["device", "install", "app", "--device", device_id, str(app)], "install", timeout=90)
        self.installed = True
        receipt.update(status="installed_pending_verification", installedAt=dt.datetime.now(UTC).isoformat())
        write_json(receipt_path, receipt)
        write_json(self.run_dir / "receipt.json", receipt)

        say("[6/6] 核对安装结果及历史/设置…")
        apps = self.device_call(["device", "info", "apps", "--device", device_id,
                                 "--bundle-id", identity["bundle"]], "app-after")["apps"]
        if len(apps) != 1 or apps[0]["version"] != signed["version"] or apps[0]["bundleVersion"] != signed["build"]:
            raise InstallError("设备返回的已安装版本与新产物不一致，请查看安装日志。")
        after = self.backup_library(device_id, identity["bundle"], "backup-after")
        write_json(self.run_dir / "data-after.json", after)
        if before != after:
            raise InstallError("已安装，但历史/设置与安装前备份不同。App 在备份时仍运行也可能引起变化；"
                               "请保留备份核对，工具不会自动还原或清除数据。")
        receipt["status"] = "installed_data_verified"
        write_json(receipt_path, receipt)
        write_json(self.run_dir / "receipt.json", receipt)
        try:
            self.device_call(["device", "process", "launch", "--device", device_id, identity["bundle"]],
                             "launch", timeout=20)
        except InstallError as error:
            say("安装和数据核对已完成，自动打开 App 未成功。请解锁后手动打开。")
            say("若显示「不受信任的开发者」：设置 → 通用 → VPN 与设备管理 → 信任自己的开发者账号。")
            say(str(error))
            return 2
        receipt["status"] = "installed_and_launched"
        write_json(receipt_path, receipt)
        write_json(self.run_dir / "receipt.json", receipt)
        # Keep receipts and private backups, not gigabytes of disposable build output.
        shutil.rmtree(self.derived)
        shutil.rmtree(self.source)
        say("完成：当前本地代码已覆盖安装并打开，历史与设置核对一致。")
        say("Mac 上的 Claude、Codex、Bridge 和通知服务未重启。")
        return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", help="有多台 iPhone 时指定设备名称或 UDID")
    parser.add_argument("--build-only", action="store_true", help="只构建并检查签名，不连接/安装手机")
    args = parser.parse_args(argv)
    if sys.platform != "darwin":
        parser.error("此工具需要 macOS 和完整 Xcode。")
    os.umask(0o077)
    state_dir = Path.home() / "Library/Application Support/CodexLink/iphone-installer"
    state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    state_dir.chmod(0o700)
    # Also prevents two clones of this tool from installing concurrently.
    with (state_dir / "run.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            say("另一个安装工具正在运行，请等待其结束。")
            return 1
        run_parent = ROOT / ".build/iphone-installer/runs"
        run_parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        run_parent.parent.chmod(0o700)
        run_dir = Path(tempfile.mkdtemp(prefix=dt.datetime.now().strftime("%Y%m%d-%H%M%S-"), dir=run_parent))
        installer = Installer(ROOT, run_dir, state_dir, args)
        say("CodexLink iPhone 更新 / 续签工具")
        say("私有日志和备份：" + str(run_dir))
        try:
            return installer.execute()
        except (InstallError, OSError, ValueError, KeyError) as error:
            say("\n停止：" + str(error))
            say("手机已覆盖安装，后续核对尚未完成；请保留日志和备份。" if installer.installed else
                "本次未完成覆盖安装；不会卸载 App、还原项目或自动使用旧安装包。")
            return 1
        except KeyboardInterrupt:
            say("\n已中断。若中断发生在安装阶段，请先查看手机状态；不会自动重试或卸载。")
            return 130


if __name__ == "__main__":
    sys.exit(main())
