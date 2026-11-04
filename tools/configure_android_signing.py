#!/usr/bin/env python3
"""CI 用：把固定的 release 簽章金鑰接到 `flutter create` 產生的 Android 專案。

為什麼需要：Flutter 預設讓 release 版用「除錯金鑰」簽章，而 GitHub Actions 每次都是
全新環境、每次都會產生不同的除錯金鑰。簽章不同的 APK 無法覆蓋安裝；
使用者若為此先解除安裝，App 私有目錄裡的本機資料庫就會一起消失。
所以必須用同一把長期保存的金鑰簽每一版。

需要的環境變數（GitHub 倉庫 Settings → Secrets and variables → Actions）：
  ANDROID_KEYSTORE_BASE64    keystore(.jks) 檔案的 base64
  ANDROID_KEYSTORE_PASSWORD  keystore 密碼
  ANDROID_KEY_ALIAS          金鑰別名
  ANDROID_KEY_PASSWORD       金鑰密碼

任何一步對不上預期的檔案內容，就直接失敗（寧可 CI 紅燈，也不要默默打出除錯簽章的 APK）。
"""
import base64
import os
import sys
from pathlib import Path

# Windows runner 的 Python 預設用 cp1252 輸出，印中文會丟 UnicodeEncodeError 讓 CI 失敗
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ANDROID = Path("android")
APP = ANDROID / "app"


def fail(msg: str) -> None:
    print(f"::error::{msg}")
    sys.exit(1)


def env(name: str) -> str:
    v = os.environ.get(name, "").strip()
    if not v:
        fail(f"缺少環境變數 {name}")
    return v


def write_keystore() -> None:
    keystore = APP / "upload-keystore.jks"
    keystore.write_bytes(base64.b64decode(env("ANDROID_KEYSTORE_BASE64")))
    props = (
        f"storePassword={env('ANDROID_KEYSTORE_PASSWORD')}\n"
        f"keyPassword={env('ANDROID_KEY_PASSWORD')}\n"
        f"keyAlias={env('ANDROID_KEY_ALIAS')}\n"
        f"storeFile={keystore.resolve()}\n"
    )
    (ANDROID / "key.properties").write_text(props, encoding="utf-8")


KTS_LOADER = """val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

"""

KTS_SIGNING = """    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
        }
    }
"""

GROOVY_LOADER = """def keystoreProperties = new Properties()
def keystorePropertiesFile = rootProject.file('key.properties')
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
}

"""

GROOVY_SIGNING = """    signingConfigs {
        release {
            keyAlias keystoreProperties['keyAlias']
            keyPassword keystoreProperties['keyPassword']
            storeFile file(keystoreProperties['storeFile'])
            storePassword keystoreProperties['storePassword']
        }
    }
"""


def patch_kts(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if 'signingConfigs.getByName("release")' in text:
        return  # 已經設定過
    old = 'signingConfig = signingConfigs.getByName("debug")'
    if old not in text:
        fail(f"{path} 找不到 `{old}`，Flutter 範本可能變了，請更新 tools/configure_android_signing.py")
    if "android {" not in text:
        fail(f"{path} 找不到 android 區塊")
    text = text.replace(old, 'signingConfig = signingConfigs.getByName("release")', 1)
    text = text.replace("android {", KTS_LOADER + "android {\n" + KTS_SIGNING, 1)
    text = "import java.io.FileInputStream\nimport java.util.Properties\n\n" + text
    path.write_text(text, encoding="utf-8")


def patch_groovy(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if "signingConfigs.release" in text:
        return
    old = "signingConfig signingConfigs.debug"
    if old not in text:
        fail(f"{path} 找不到 `{old}`，Flutter 範本可能變了，請更新 tools/configure_android_signing.py")
    if "android {" not in text:
        fail(f"{path} 找不到 android 區塊")
    text = text.replace(old, "signingConfig signingConfigs.release", 1)
    text = text.replace("android {", GROOVY_LOADER + "android {\n" + GROOVY_SIGNING, 1)
    text = "import java.io.FileInputStream\n\n" + text
    path.write_text(text, encoding="utf-8")


def main() -> None:
    kts = APP / "build.gradle.kts"
    groovy = APP / "build.gradle"
    if not (kts.exists() or groovy.exists()):
        fail("找不到 android/app/build.gradle(.kts)，請先執行 flutter create")
    write_keystore()
    if kts.exists():
        patch_kts(kts)
    else:
        patch_groovy(groovy)
    print("Android release 簽章已設定")


if __name__ == "__main__":
    main()
