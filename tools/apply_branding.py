#!/usr/bin/env python3
"""CI / 本機用：把「愛車記錄」的專屬圖示與顯示名稱套用到 `flutter create` 產生的平台專案。

用法：python3 tools/apply_branding.py android|windows

- android：複製 branding/android/res 的圖示（舊版 + 自適應圖示）到 android/app/src/main/res，
           並把桌面顯示名稱（android:label）改成「愛車記錄」。
- windows：用 branding/windows/app_icon.ico 取代 exe 圖示，視窗標題改成「愛車記錄」。

沒有這一步時，`flutter create` 會留下 Flutter 預設圖示，和其他 Flutter App 看起來一樣。
圖示本身用 tools/make_icon.py 產生，已提交在 branding/，這裡只負責複製（不需要 Pillow）。
圖示檔複製失敗會讓 CI 失敗；顯示名稱的文字取代找不到目標只會警告（不影響功能）。
"""
import re
import shutil
import sys
from pathlib import Path

NAME = "愛車記錄"
BRANDING = Path("branding")


def fail(msg: str) -> None:
    print(f"::error::{msg}")
    sys.exit(1)


def warn(msg: str) -> None:
    print(f"::warning::{msg}")


def android() -> None:
    src = BRANDING / "android" / "res"
    dst = Path("android/app/src/main/res")
    if not src.is_dir():
        fail(f"找不到 {src}")
    if not dst.is_dir():
        fail(f"找不到 {dst}，請先執行 flutter create")
    shutil.copytree(src, dst, dirs_exist_ok=True)

    manifest = Path("android/app/src/main/AndroidManifest.xml")
    text = manifest.read_text(encoding="utf-8")
    new, n = re.subn(r'android:label="[^"]*"', f'android:label="{NAME}"', text, count=1)
    if n == 0:
        warn("AndroidManifest.xml 找不到 android:label，桌面名稱維持預設")
    else:
        manifest.write_text(new, encoding="utf-8")
    print("Android 圖示與名稱已套用")


def windows() -> None:
    src = BRANDING / "windows" / "app_icon.ico"
    dst = Path("windows/runner/resources/app_icon.ico")
    if not src.is_file():
        fail(f"找不到 {src}")
    if not dst.parent.is_dir():
        fail(f"找不到 {dst.parent}，請先執行 flutter create")
    shutil.copyfile(src, dst)

    main_cpp = Path("windows/runner/main.cpp")
    text = main_cpp.read_text(encoding="utf-8")
    # 用 \uXXXX 跳脫，不受原始檔編碼（MSVC 預設非 UTF-8）影響
    escaped = "".join(f"\\u{ord(c):04x}" for c in NAME)
    old = 'L"garage_log"'
    n = text.count(old)
    new = text.replace(old, f'L"{escaped}"', 1)
    if n == 0:
        warn("main.cpp 找不到視窗標題 L\"garage_log\"，視窗標題維持預設")
    else:
        main_cpp.write_text(new, encoding="utf-8")
    print("Windows 圖示與視窗標題已套用")


def main() -> None:
    if len(sys.argv) != 2 or sys.argv[1] not in ("android", "windows"):
        fail("用法：apply_branding.py android|windows")
    android() if sys.argv[1] == "android" else windows()


if __name__ == "__main__":
    main()
