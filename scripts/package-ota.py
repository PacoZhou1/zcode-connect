#!/usr/bin/env python3
"""package-ota.py — 为 ZCodeMobile 打包并发布非局域网 OTA 安装包。

流程：
  1. 确保 Release 构建存在（可增量复用 /tmp 派生数据）
  2. xcodebuild archive 生成 .xcarchive（存在则复用，--force-archive 重建）
  3. xcodebuild -exportArchive（development 方法）导出 IPA
  4. 校验 IPA：codesign --verify --strict、embedded.mobileprovision 含目标设备 UDID、
     bundle id 与签名团队匹配，打印 profile 过期时间
  5. 生成 Apple OTA manifest.plist（HTTPS 绝对地址）
  6. 通过 scp/ssh 上传 IPA + manifest + 图标到 Mac Pro OTA 目录（0700/0600）
  7. 验证公网 URL（manifest 与 IPA 的 HEAD 响应、Content-Length 一致）
  8. 打印 itms-services 安装链接与二维码（依赖 qrencode，缺失则说明并跳过）

脚本幂等：重复运行会覆盖同一批远端文件（覆盖前打印清单）。
不会改动仓库 ios/ 源码；仅在本脚本与 work 目录内写文件。

用法（项目根目录）：
  python3 scripts/package-ota.py                # 完整流程：构建→导出→校验→上传→验证
  python3 scripts/package-ota.py --no-upload    # 只到本地 IPA + 校验为止
  python3 scripts/package-ota.py --force-archive # 强制重新 archive
"""

import argparse
import hashlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import zipfile
from datetime import datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# 缺省值与仓库/服务器现状对齐（可用命令行参数覆盖）
DEF = {
    "team_id": "KA9U6H75UJ",
    "bundle_id": "dev.paco.zcode.mobile",
    "scheme": "ZCodeMobile",
    "project": "ios/ZCodeMobile.xcodeproj",
    "derived_data": "/tmp/zcode-native-device-135",
    "work_dir": "/tmp/zcode-native-ota",
    "ssh_host": "bumiao",
    "remote_dir": "/Users/workflow/zcode-ota",
    "base_url": "https://example.com:8443/ota",
    "device_udid": "00008150-001A4CEA3642401C",
    "app_name": "ZCodeMobile",
}


def sh(cmd, *, capture=False, check=True, env=None):
    """运行命令；长命令输出写入日志文件，失败时回显末尾若干行。"""
    printable = " ".join(str(c) for c in cmd)
    print(f"  + {printable}")
    if capture:
        p = subprocess.run(cmd, capture_output=True, text=True, env=env)
        if check and p.returncode != 0:
            sys.stderr.write(p.stdout[-4000:] + "\n" + p.stderr[-4000:] + "\n")
            raise SystemExit(f"命令失败（exit {p.returncode}）：{printable}")
        return p
    p = subprocess.run(cmd, env=env)
    if check and p.returncode != 0:
        raise SystemExit(f"命令失败（exit {p.returncode}）：{printable}")
    return p


def step(n, total, msg):
    print(f"\n[{n}/{total}] {msg}")


def path_or_die(p: Path, what: str) -> Path:
    if not p.exists():
        raise SystemExit(f"{what}不存在：{p}")
    return p


def ensure_release_build(a, dd: Path, total):
    step(1, total, "确保 Release 构建存在（增量复用）")
    app = dd / "Build/Products/Release-iphoneos" / f"{a.app_name}.app"
    if app.exists():
        print(f"  复用已有构建：{app}")
        return app
    print("  本地无 Release 构建，执行完整 build …")
    sh([
        "xcodebuild", "-project", str(REPO_ROOT / a.project),
        "-scheme", a.scheme, "-configuration", "Release",
        "-destination", "generic/platform=iOS",
        "-derivedDataPath", str(dd),
        f"DEVELOPMENT_TEAM={a.team_id}", "-allowProvisioningUpdates", "build",
    ])
    return path_or_die(app, "Release 构建")


def ensure_archive(a, dd: Path, total) -> Path:
    step(2, total, "生成 .xcarchive（exportArchive 的输入）")
    archive = Path(a.work_dir) / f"{a.app_name}.xcarchive"
    if archive.exists() and not a.force_archive:
        print(f"  复用已有 archive：{archive}（--force-archive 可重建）")
        return archive
    if archive.exists():
        print(f"  删除旧 archive：{archive}")
        shutil.rmtree(archive)
    sh([
        "xcodebuild", "-project", str(REPO_ROOT / a.project),
        "-scheme", a.scheme, "-configuration", "Release",
        "-destination", "generic/platform=iOS",
        "-derivedDataPath", str(dd),
        "-archivePath", str(archive),
        f"DEVELOPMENT_TEAM={a.team_id}", "-allowProvisioningUpdates", "archive",
    ])
    return path_or_die(archive, "xcarchive")


def export_ipa(a, archive: Path, total) -> Path:
    step(3, total, "xcodebuild -exportArchive 导出 IPA（development 方法）")
    work = Path(a.work_dir)
    opts = work / "ExportOptions.plist"
    export_dir = work / "export"
    options_plist = {
        "method": "development",
        "teamID": a.team_id,
        "signingStyle": "automatic",
        "stripSwiftSymbols": True,
    }
    with open(opts, "wb") as f:
        plistlib.dump(options_plist, f)
    print(f"  已写 ExportOptions.plist：{opts}")
    if export_dir.exists():
        shutil.rmtree(export_dir)
    sh([
        "xcodebuild", "-exportArchive",
        "-archivePath", str(archive),
        "-exportOptionsPlist", str(opts),
        "-exportPath", str(export_dir),
        "-allowProvisioningUpdates",
    ])
    ipas = sorted(export_dir.glob("*.ipa"))
    if not ipas:
        raise SystemExit(f"导出目录没有 IPA：{export_dir}")
    print(f"  导出 IPA：{ipas[0]}（{ipas[0].stat().st_size} 字节）")
    return ipas[0]


def verify_ipa(a, ipa: Path, total) -> dict:
    step(4, total, "校验 IPA：签名 / 设备 UDID / bundle id / 过期时间")
    info = {}
    vdir = Path(a.work_dir) / "verify"
    if vdir.exists():
        shutil.rmtree(vdir)
    vdir.mkdir(parents=True)
    with zipfile.ZipFile(ipa) as z:
        z.extractall(vdir)
    app = vdir / "Payload" / f"{a.app_name}.app"
    path_or_die(app, "IPA 内的 .app")

    print("  -- codesign --verify --strict")
    sh(["codesign", "--verify", "--strict", str(app)])
    p = sh(["codesign", "-dv", str(app)], capture=True)
    for line in p.stderr.splitlines():
        if line.strip().startswith(("Authority=", "TeamIdentifier=", "Identifier=")):
            print("     " + line.strip())
            info.setdefault("codesign", []).append(line.strip())

    prof = app / "embedded.mobileprovision"
    path_or_die(prof, "embedded.mobileprovision")
    raw = sh(["security", "cms", "-D", "-i", str(prof)], capture=True).stdout
    pl = plistlib.loads(raw.encode())
    info["profile_name"] = pl.get("Name", "")
    info["expiration"] = str(pl.get("ExpirationDate", ""))
    info["team_name"] = pl.get("TeamName", "")
    devices = pl.get("ProvisionedDevices") or []
    print(f"  profile 名称 : {info['profile_name']}")
    print(f"  团队         : {info['team_name']}")
    print(f"  过期时间     : {info['expiration']}")
    print(f"  已注册设备数 : {len(devices)}")
    if a.device_udid in devices:
        print(f"  目标设备 UDID {a.device_udid} ✔ 在 profile 内")
    else:
        raise SystemExit(f"目标设备 UDID {a.device_udid} 不在 profile 的 ProvisionedDevices 内！")
    info["udid_ok"] = True

    with open(app / "Info.plist", "rb") as f:
        app_pl = plistlib.load(f)
    got_bid = app_pl.get("CFBundleIdentifier", "")
    ver = app_pl.get("CFBundleShortVersionString", "")
    build = app_pl.get("CFBundleVersion", "")
    print(f"  bundle id    : {got_bid}（版本 {ver} build {build}）")
    if got_bid != a.bundle_id:
        raise SystemExit(f"bundle id 不匹配：{got_bid} != {a.bundle_id}")
    info["bundle_id"], info["version"], info["build"] = got_bid, ver, build

    ent = sh(["codesign", "-d", "--entitlements", ":-", str(app)], capture=True).stdout
    if f"{a.team_id}.{a.bundle_id}" in ent:
        print(f"  签名 entitlement application-identifier = {a.team_id}.{a.bundle_id} ✔")
    else:
        raise SystemExit("entitlement 中未找到预期的 application-identifier！")
    return info


def build_manifest(a, total) -> Path:
    step(5, total, "生成 OTA manifest.plist")
    work = Path(a.work_dir)
    ipa_url = f"{a.base_url}/{a.app_name}.ipa"
    manifest = {
        "items": [
            {
                "assets": [
                    {"kind": "software-package", "url": ipa_url},
                    {"kind": "display-image", "url": f"{a.base_url}/icon-120.png",
                     "needs-shine": False},
                ],
                "metadata": {
                    "bundle-identifier": a.bundle_id,
                    "bundle-version": a.version,
                    "kind": "software",
                    "title": a.app_name,
                    "subtitle": "ZCode Mobile",
                },
            }
        ]
    }
    out = work / "manifest.plist"
    with open(out, "wb") as f:
        plistlib.dump(manifest, f)
    print(f"  已写 {out}")
    print(f"  software-package URL：{ipa_url}（HTTPS 绝对地址）")

    # 图标：复用 app bundle 内置的 120x120 AppIcon（display-image 可选项）
    src_icon = work / "verify/Payload" / f"{a.app_name}.app" / "AppIcon60x60@2x.png"
    if src_icon.exists():
        shutil.copy(src_icon, work / "icon-120.png")
        print("  图标：icon-120.png（来自 AppIcon60x60@2x.png）")
    else:
        print("  警告：未找到 AppIcon60x60@2x.png，display-image 将跳过")
        manifest["items"][0]["assets"] = [manifest["items"][0]["assets"][0]]
        with open(out, "wb") as f:
            plistlib.dump(manifest, f)
    return out


def upload(a, files: list, total):
    step(6, total, f"上传到 {a.ssh_host}:{a.remote_dir}")
    files = [f for f in files if f.exists()]
    print("  远端已有文件（本次将被覆盖）：")
    p = subprocess.run(
        ["ssh", a.ssh_host,
         f"mkdir -p '{a.remote_dir}' && chmod 700 '{a.remote_dir}' && "
         f"ls -l '{a.remote_dir}' 2>/dev/null || echo '  （目录为空，首次部署）'"],
        capture_output=True, text=True)
    print("  " + (p.stdout.strip() or "（无）"))
    if p.returncode != 0:
        raise SystemExit(f"ssh 预检失败：{p.stderr}")
    sh(["scp", "-p", *[str(f) for f in files],
        f"{a.ssh_host}:{a.remote_dir}/"])
    names = " ".join(f"'{a.remote_dir}/{f.name}'" for f in files)
    sh(["ssh", a.ssh_host, f"chmod 600 {names} && ls -l '{a.remote_dir}'"])

    print("  校验远端 sha256：")
    local = {f.name: hashlib.sha256(f.read_bytes()).hexdigest() for f in files}
    p = subprocess.run(["ssh", a.ssh_host, f"shasum -a 256 {names}"],
                       capture_output=True, text=True, check=True)
    for line in p.stdout.strip().splitlines():
        digest, name = line.split(None, 1)
        name = Path(name.strip()).name
        ok = local.get(name) == digest
        print(f"    {name}: {'一致 ✔' if ok else '不一致 ✘ ' + digest}")
        if not ok:
            raise SystemExit(f"远端 {name} sha256 与本地不一致，上传异常，中止。")


def verify_urls(a, ipa: Path, total):
    step(7, total, "验证公网 URL（HEAD）")
    checks = [
        (f"{a.base_url}/manifest.plist", None),
        (f"{a.base_url}/{a.app_name}.ipa", ipa.stat().st_size),
    ]
    for url, expect_len in checks:
        p = subprocess.run(["curl", "-sI", "--max-time", "30", url],
                           capture_output=True, text=True)
        head = p.stdout
        status = next((l for l in head.splitlines() if l.startswith("HTTP/")), "?")
        ctype = next((l for l in head.splitlines() if l.lower().startswith("content-type")), "?")
        clen = next((l for l in head.splitlines() if l.lower().startswith("content-length")), "?")
        print(f"  {url}\n    {status.strip()} | {ctype.strip()} | {clen.strip()}")
        code = status.split()[1] if len(status.split()) > 1 else "0"
        if code != "200":
            raise SystemExit(f"{url} 返回 {code}，预期 200")
        if expect_len is not None:
            got_len = clen.split(":", 1)[1].strip() if ":" in clen else ""
            if got_len == str(expect_len):
                print(f"    Content-Length 与本地一致（{expect_len} 字节）✔")
            else:
                raise SystemExit(f"Content-Length 与本地 {expect_len} 不一致：{clen.strip()}")


def print_link_and_qr(a, total):
    step(8, total, "安装链接与二维码")
    manifest_url = f"{a.base_url}/manifest.plist"
    link = ("itms-services://?action=download-manifest&url="
            + urllib.parse.quote(manifest_url, safe=""))
    print("\n" + "=" * 64)
    print(f"  OTA 安装链接（在 iPhone Safari 打开）:\n  {link}")
    print(f"  manifest: {manifest_url}")
    print("=" * 64)
    qrencode = shutil.which("qrencode")
    if qrencode:
        subprocess.run([qrencode, "-t", "ANSIUTF8", "-o", "-", link])
        png = Path(a.work_dir) / "install-qr.png"
        subprocess.run([qrencode, "-o", str(png), "-s", "8", "-m", "2", link], check=True)
        print(f"  二维码 PNG 已保存：{png}（iPhone 相机扫码即可安装）")
    else:
        print("  未安装 qrencode，跳过二维码。可 `brew install qrencode` 后重跑。")
    print("  约束：仅 profile 内注册的设备可安装；development profile 到期后需重新打包。")


def main():
    ap = argparse.ArgumentParser(description="ZCodeMobile OTA 打包与发布")
    for k, v in DEF.items():
        ap.add_argument(f"--{k.replace('_', '-')}", default=v, help=f"默认 {v}")
    ap.add_argument("--force-archive", action="store_true", help="强制重新 archive")
    ap.add_argument("--no-upload", action="store_true", help="不上传，只生成本地 IPA")
    a = ap.parse_args()

    dd = Path(a.derived_data)
    Path(a.work_dir).mkdir(parents=True, exist_ok=True)
    print(f"项目根      : {REPO_ROOT}")
    print(f"派生数据    : {dd}")
    print(f"工作目录    : {a.work_dir}")
    print(f"目标设备    : {a.device_udid}")
    print(f"公网基址    : {a.base_url}")
    sh(["xcodebuild", "-version"], capture=True)

    total = 8
    ensure_release_build(a, dd, total)
    archive = ensure_archive(a, dd, total)
    ipa = export_ipa(a, archive, total)
    info = verify_ipa(a, ipa, total)
    a.version = info["version"]  # build_manifest 需要 CFBundleShortVersionString
    manifest = build_manifest(a, total)
    files = [ipa, manifest, Path(a.work_dir) / "icon-120.png"]
    if a.no_upload:
        print("\n--no-upload：跳过上传与 URL 验证。")
    else:
        upload(a, files, total)
        verify_urls(a, ipa, total)
    print_link_and_qr(a, total)
    print("\n完成。IPA 过期时间（profile）：", info["expiration"])


if __name__ == "__main__":
    main()
