# 愛車記錄 garage_log

純本地、無廣告、輕量化的汽機車「油耗與保養」記錄 App。
一份 Flutter 程式碼，同時產出 **Android APK** 與 **Windows 桌面 (.exe)**。

- 多車輛（汽車 / 機車）切換
- 加油記錄與油耗計算（以「跳停」為區間基準）、里程防呆
- 保養維修記錄（常用項目快速選單、數量 × 單價自動累加）
- 統計圖表：歷次油耗折線圖、每月花費（加油 vs 保養）長條圖
- 手機直立 → 底部導覽列；Windows 寬螢幕 → 側邊欄
- 全部資料只存在本機 SQLite；沒有帳號、沒有伺服器、沒有廣告
- 全資料庫 JSON 匯出 / 匯入（合併式），做為現階段的跨裝置手動同步

## 專案結構

```
garage_log/
├─ pubspec.yaml
├─ analysis_options.yaml
├─ .github/workflows/build.yml      # CI：測試 + 編 APK + 編 Windows，tag v* 自動發佈 Release
├─ lib/
│  ├─ main.dart
│  ├─ providers.dart                # Riverpod：DB / Repository / 目前車輛 / 各列表 Stream
│  ├─ data/
│  │  ├─ tables.dart                # Drift Schema（UUID 主鍵 + 同步欄位 + 軟刪除）
│  │  ├─ database.dart              # AppDatabase
│  │  ├─ connection.dart            # 開啟本機 SQLite（Android / Windows 共用）
│  │  ├─ repository.dart            # 所有讀寫；一律軟刪除、一律更新 updatedAt
│  │  ├─ backup_service.dart        # 全資料庫 JSON 匯出 / 合併匯入（LWW）
│  │  └─ sync_service.dart          # SyncBackend 抽象 + 資料夾後端（雲端同步預留）
│  ├─ domain/                       # 純 Dart，無 Flutter / Drift 依賴，易於測試
│  │  ├─ fuel_calculator.dart       # 油耗計算、里程防呆
│  │  ├─ maintenance_calculator.dart# 明細小計 / 總額、常用項目
│  │  └─ cost_summary.dart          # 每月花費彙總
│  └─ ui/
│     ├─ home_shell.dart            # 響應式外框（側邊欄 / 底部導覽）、車輛切換
│     ├─ fuel_page.dart / fuel_form.dart
│     ├─ maintenance_page.dart / maintenance_form.dart
│     ├─ stats_page.dart            # fl_chart
│     ├─ vehicles_page.dart / vehicle_form.dart
│     └─ settings_page.dart         # 匯出 / 匯入
└─ test/
   ├─ fuel_calculator_test.dart     # 純邏輯測試（不需要 SQLite）
   └─ backup_service_test.dart      # 記憶體資料庫：UUID、匯出入、LWW、里程防呆
```

> `android/`、`windows/` 平台資料夾不放在倉庫裡，由 `flutter create` 產生（本機或 CI 自動做）。
> `*.g.dart` 由 build_runner 產生，已加入 `.gitignore`。

## 為「未來同步」預留的設計

| 項目 | 做法 |
|---|---|
| 主鍵 | 所有實體 `id` 為 UUID v4 字串，沒有任何自動遞增整數 |
| 時間戳 | 每個實體都有 `created_at`、`updated_at`（epoch 毫秒） |
| 刪除 | `is_deleted` 軟刪除（墓碑），刪除也能同步；所有查詢都過濾已刪除列 |
| 外鍵 | 刻意不建 FK 約束，合併時子資料可能先於父資料抵達 |
| 合併規則 | 以 `updated_at` 較新者為準（Last-Write-Wins）；相同或較舊略過 |
| 匯出 | 含墓碑的全資料庫 JSON，帶 `app` / `formatVersion` 供版本檢查 |
| 匯入 | 合併而非覆蓋，重複匯入安全；整批在單一交易內，失敗整批回滾 |
| 後端 | `SyncBackend`（讀 / 寫一份 JSON）。已有 `FolderSyncBackend`；之後可加 Google Drive appDataFolder、WebDAV，不必動合併邏輯 |

手動同步流程：A 裝置「設定 → 匯出」→ 把 JSON 傳到 B → B「設定 → 匯入」。兩邊可以來回做。

> 限制：LWW 依賴各裝置時鐘大致正確。同一筆資料在兩台裝置「同時」被修改時，較晚修改的那台勝出。

## 油耗計算規則

以「跳停（加滿）」為區間基準，依日期、里程排序後計算：

1. **第一筆加滿**只記錄為起點，不計算油耗（油箱起始狀態未知；它之前的未加滿紀錄也忽略）。
2. 之後每一筆加滿：
   - 區間里程 = 本次里程 − 上次加滿里程
   - 平均油耗 (km/L) = 區間里程 ÷ 公升數
   - 每公里花費 = 金額 ÷ 區間里程
3. **中間有「未加滿」補油時**：公升數與金額會累計到下一次加滿一起算。
   沒有補油時就是單純的「區間里程 ÷ 本次公升數」。
4. 首頁的「平均油耗」是總里程 ÷ 總公升的加權平均，不是各次油耗的算術平均。

**里程防呆**：新增 / 編輯時里程必須大於上一筆；插入歷史中間時也必須小於下一筆；沒有上一筆時不可小於車輛初始里程。同一天多筆加油請依里程順序輸入。

## 環境需求

- Flutter stable（含 Dart 3.5+）
- Android：Android SDK（`flutter doctor` 會引導安裝）、JDK 17
- Windows：Visual Studio 2022，勾選「使用 C++ 的桌面開發」工作負載

> **SQLite 說明**：drift 2.32+ 搭配 `sqlite3` 3.x，SQLite 由 build hooks 在編譯時自動打包（需要 C 編譯器，
> 上述工具鏈已包含）。舊的 `sqlite3_flutter_libs` 已 EOL（0.6.0+eol），本專案不再使用。

## 第一次建置（本機）

```bash
git clone <你的倉庫網址> garage_log
cd garage_log

# 1. 產生平台資料夾（只需做一次）
flutter create --platforms=android,windows --project-name garage_log --org com.example .

# 2. 安裝套件
flutter pub get

# 3. 產生 Drift 程式碼（改了 tables.dart 之後也要重跑）
dart run build_runner build --delete-conflicting-outputs

# 4. 測試
flutter test
```

## 打包 Android APK

```bash
flutter build apk --release
# 輸出：build/app/outputs/flutter-apk/app-release.apk
# 只給特定 CPU：flutter build apk --release --split-per-abi
```

- 預設 release 會用 **debug 簽章**，可直接安裝自用。
- 要正式發佈或讓使用者無痛更新，請建立自己的 keystore 並設定 `android/key.properties`
  與 `android/app/build.gradle(.kts)` 的 `signingConfigs`。**簽章檔絕對不要上傳到倉庫**（`.gitignore` 已排除 `key.properties`、`*.jks`）。
  同一個 App 之後的版本必須用同一把 key 簽章，否則無法覆蓋安裝。
- 想改套件名稱：把 `--org com.example` 換成自己的網域（要在第一次 `flutter create` 時決定，之後改很麻煩）。

## 打包 Windows 桌面版

```bash
flutter build windows --release
# 輸出資料夾：build\windows\x64\runner\Release\
```

**Windows release 注意事項**

1. **要發佈整個 `Release\` 資料夾**，不能只拿 `garage_log.exe`。
   資料夾內的 `flutter_windows.dll`、`data\`（含 `flutter_assets`、`icudtl.dat`、`app.so`）與外掛 DLL 都是執行必需。
   最簡單的做法是整個資料夾壓成 zip。
2. **VC++ 執行階段**：全新的 Windows 若沒有 Visual C++ Redistributable，會因缺少 `msvcp140.dll` / `vcruntime140.dll` 而打不開。
   解法擇一：請使用者安裝 VC++ 2015-2022 Redistributable (x64)；或把這些 DLL 放進 `Release\` 與 exe 同層。
3. **想要單一安裝檔**：用 [Inno Setup](https://jrsoftware.org/isinfo.php) 把 `Release\` 打成 `setup.exe`，
   或用 `msix` 套件產生 MSIX（MSIX 需要簽章憑證）。
4. **SmartScreen 警告**：未簽章的 exe 第一次執行會跳「Windows 已保護您的電腦」，選「其他資訊 → 仍要執行」。要消除警告需購買程式碼簽章憑證。
5. **資料位置**：SQLite 檔在使用者的「文件」資料夾 `garage_log\garage_log.sqlite`（`getApplicationDocumentsDirectory()`）。
   解除安裝或刪資料夾不會自動清掉它；要備份請直接用 App 內的匯出。
6. 只能在 Windows 上編 Windows 版（Flutter 不支援跨平台編譯桌面版）；沒有 Windows 機器時用下面的 GitHub Actions。

## GitHub Actions（建議的驗證方式）

`.github/workflows/build.yml` 會在 push 時：

1. `test` job：`build_runner` → `flutter analyze` → `flutter test`
2. `android` job：產生平台資料夾 → 編 APK → 上傳 artifact
3. `windows` job（windows-latest）：編 Windows → 壓成 zip → 上傳 artifact
4. 推 `v*` tag（例如 `v0.1.0`）時，自動建立 Release 並附上 APK 與 Windows zip

私有倉庫也可使用（受每月免費分鐘數限制）。到 Actions 頁面下載 artifact 即可安裝測試。

## 之後的路線

- Google Drive `appDataFolder` 後端（實作 `SyncBackend`，登入自己的 Google 帳號，資料只存在使用者自己的雲端）
- 保養提醒（依里程 / 日期）
- CSV 匯出

## 授權

MIT，見 `LICENSE`。
