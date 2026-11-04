# 愛車記錄 garage_log

純本地、無廣告、輕量化的汽機車「油耗與保養」記錄 App。
一份 Flutter 程式碼，同時產出 **Android APK** 與 **Windows 桌面 (.exe)**。

## 功能

- **總覽首頁**：目前里程、最近平均油耗、本月花費、近期保養提醒、快速新增、最近紀錄
- **多車輛**（汽車 / 機車）切換，記住上次使用的車，每台車可設預設油品
- **加油與油耗**：以「跳停」為區間基準、同日多筆里程防呆、油品（92 / 95 / 98 / 柴油）、
  「輸入實付金額」或「輸入單價」二選一計價（不會互相覆寫）
- **保養維修**：數量 × 單價自動累加、汽機車各自的常用項目、可自訂常用項目
- **保養週期與零件歷史**：自訂里程 / 天數週期，顯示「上次更換、下次預計、還剩多少」，
  並整理每個零件的完整更換歷史（不需要另外輸入）
- **統計**：近 3 個月 / 近 12 個月 / 全部；油耗折線圖（直線連接實測值）、每月花費長條圖、
  每公里費用（只含加油 / 加油＋保養分開標示）、與前一期比較、油耗異常提醒
- **搜尋與篩選**：加油、保養列表可依年份與關鍵字查詢
- **備份、同步與復原**：全資料庫 JSON 匯出 / 匯入（合併式、匯入前預覽、自動備份）、
  **自動備份清單與完整復原**、CSV 匯出（Excel 可開）
- 手機直立 → 底部導覽列；Windows 寬螢幕 → 側邊欄
- **今日油價**：首頁顯示台灣中油公開牌價（98 / 95 / 92 / 柴油）。這是 App 唯一會連網的功能：
  只對中油公開網址發出讀取請求，**不上傳任何資料**；取不到時顯示上次的快取；可在「設定」整個關閉，關閉後完全不連網
- **里程依日期判定**：新增 / 編輯加油與保養時，先選日期，里程欄下方會顯示該日期的合理範圍（加油與保養一起比對）
- 你的行車資料只存在本機 SQLite；沒有帳號、沒有伺服器、沒有廣告

## 專案結構

```
garage_log/
├─ pubspec.yaml
├─ analysis_options.yaml
├─ CHANGELOG.md
├─ .github/workflows/build.yml      # CI：測試 + 編 APK（固定金鑰簽章）+ 編 Windows，tag v* 自動發佈 Release
├─ tools/configure_android_signing.py  # CI 用：把固定 release 金鑰接到 Android 專案
├─ tools/apply_branding.py          # CI 用：套用專屬圖示與顯示名稱「愛車記錄」到 Android / Windows
├─ tools/make_icon.py               # 重新產生圖示（需 Pillow；輸出到 branding/）
├─ branding/                        # 已產生好的圖示（Android 各解析度 + 自適應圖示、Windows .ico）
├─ lib/
│  ├─ main.dart
│  ├─ providers.dart                # Riverpod：DB / Repository / 目前車輛 / 提醒 / 統計期間
│  ├─ data/
│  │  ├─ tables.dart                # Drift Schema（UUID 主鍵 + 同步欄位 + 軟刪除）
│  │  ├─ database.dart              # AppDatabase（schema v2 與遷移）
│  │  ├─ connection.dart            # 開啟本機 SQLite（Android / Windows 共用）
│  │  ├─ clock.dart                 # 單調遞增時鐘（updatedAt 不重複、不倒退）
│  │  ├─ repository.dart            # 所有讀寫、驗證與歸屬檢查；一律軟刪除、一律更新 updatedAt
│  │  ├─ backup_service.dart        # JSON 匯出 / 預覽 / 合併匯入（LWW）/ 一致性修復 / 異常檢查 / 完整復原 / 自動備份
│  │  ├─ csv_export.dart            # CSV 匯出
│  │  └─ sync_service.dart          # SyncBackend 抽象 + 資料夾後端（雲端同步預留）
│  ├─ domain/                       # 純 Dart，無 Flutter / Drift 依賴，易於測試
│  │  ├─ fuel_calculator.dart       # 油耗計算、里程防呆
│  │  ├─ maintenance_calculator.dart# 明細驗證與金額、汽機車常用項目
│  │  ├─ reminders.dart             # 保養週期提醒、零件歷史
│  │  ├─ stats_summary.dart         # 統計期間彙總、異常偵測
│  │  └─ cost_summary.dart          # 每月花費彙總
│  └─ ui/
│     ├─ home_shell.dart            # 響應式外框（側邊欄 / 底部導覽）、車輛切換
│     ├─ dashboard_page.dart        # 總覽
│     ├─ fuel_page.dart / fuel_form.dart
│     ├─ maintenance_page.dart / maintenance_form.dart
│     ├─ plans_page.dart            # 保養週期、零件歷史
│     ├─ stats_page.dart            # fl_chart
│     ├─ vehicles_page.dart / vehicle_form.dart
│     ├─ settings_page.dart         # 備份 / 匯入 / CSV
│     ├─ restore_page.dart          # 自動備份清單、完整復原
│     └─ common.dart / format.dart / navigation.dart / reminder_widgets.dart
└─ test/                            # 單元測試、遷移測試、Widget 測試
```

> `android/`、`windows/` 平台資料夾不放在倉庫裡，由 `flutter create` 產生（本機或 CI 自動做）。
> `*.g.dart` 由 build_runner 產生，已加入 `.gitignore`。
> `pubspec.lock` **要進版控**（App 專案應固定依賴版本）；第一次在有 Flutter 的環境執行 `flutter pub get` 後提交它。

## 為「未來同步」預留的設計

| 項目 | 做法 |
|---|---|
| 主鍵 | 所有實體 `id` 為 UUID v4 字串，沒有任何自動遞增整數 |
| 時間戳 | 每個實體都有 `created_at`、`updated_at`（epoch 毫秒）。每次寫入的 `updated_at` 保證**嚴格大於該列原本的值**（同一毫秒連續編輯、或該列來自時鐘較快的裝置都一樣） |
| 刪除 | `is_deleted` 軟刪除（墓碑），刪除也能同步；所有查詢都過濾已刪除列 |
| 外鍵 | 刻意不建 FK 約束，合併時子資料可能先於父資料抵達 |
| 合併規則 | 以 `updated_at` 較新者為準（Last-Write-Wins）；較舊略過。`updated_at` **相同但內容不同**時，以內容的穩定排序決勝，兩台裝置各自合併都會選同一邊，結果會收斂 |
| 匯出 | 含墓碑的全資料庫 JSON，帶 `app` / `formatVersion`（目前 2；可匯入 v1 備份） |
| 匯入 | 合併而非覆蓋，重複匯入安全；整批在單一交易內，失敗整批回滾 |
| 匯入前 | 先**預覽**（備份時間、各類筆數、合併後新增 / 更新 / 略過），確認後**自動備份**目前資料（保留最近 5 份） |
| 一致性修復 | 匯入後自動：① 已刪除的車輛 / 保養單底下新出現的紀錄一併刪除 ② 保養單總額依未刪除明細重算。修正時 `updated_at` 一定比被修正的那列新，不會被下一次同步的舊資料蓋回去 |
| 異常資料 | 找不到所屬車輛 / 保養單的**孤立紀錄**、**沒有任何有效明細的保養單**：不刪除、不改金額，只**隔離保留**，並在匯入預覽與結果中回報筆數，讓你確認備份來源。異常保養單**不會出現在列表、總覽、統計與 CSV**，也不會計入保養累計花費 |
| 備份檢查 | 依 `formatVersion` 檢查必要資料表（v2 必須 5 張表齊全）與欄位值，任何一筆不合法就**整份拒絕**，資料庫不變。未刪除的資料套用和 App 內輸入**相同的規則**（名稱不可空白、公升 / 數量 > 0、金額 / 單價 / 里程 >= 0、數字必須有限）；已刪除的墓碑只要求數字有限、非負 |
| 後端 | `SyncBackend`（讀 / 寫一份 JSON）。已有 `FolderSyncBackend`；同步時寫回前會重讀遠端，期間被改過就重新合併。重試用完遠端仍在變動時，丟出 `SyncConflictException` 並**取消同步，絕不強制覆寫遠端** |

手動同步流程：A 裝置「設定 → 匯出」→ 把 JSON 傳到 B → B「設定 → 匯入」。兩邊可以來回做。

> 限制：LWW 依賴各裝置時鐘大致正確；同一筆資料在兩台裝置「同時」被修改時，較晚修改的那台勝出。
> 「寫回前重讀」只能縮小競爭視窗，**不是真正的鎖**（比對之後、寫入之前仍可能有別台裝置寫入）。
> 所以目前**只提供手動匯出 / 匯入**，沒有全自動同步；要做自動同步，後端必須支援版本驗證 / 條件式寫入（例如 ETag）。
> 備份檔未加密，內含車牌、里程與維修紀錄，請妥善保管。

## 備份、匯入與完整復原

| 操作 | 行為 | 什麼時候用 |
|---|---|---|
| **匯入並合併** | 保留兩邊較新的修改，不會讓資料回到過去 | 兩台裝置互相同步 |
| **完整復原** | 讓資料回到某份備份當時的狀態；備份之後新增的紀錄以墓碑處理（不是真的刪掉），復原結果的 `updated_at` 會比本機原值與備份值都新，所以之後同步給其他裝置也會勝出 | 匯入或誤操作後想整個退回去 |

- 匯入前會自動備份，**完整復原前也會自動備份**；兩種各保留最近 5 份。
- 完整復原前的確認畫面會列出**目前 / 備份 / 將移除**的筆數（車輛、加油、保養、週期），讓你知道會影響多少本機資料。
- 自動備份在 App 私有目錄（一般檔案管理器看不到）。到「設定 → 自動備份與完整復原」可以查看清單、
  **另存一份**到看得到的位置，或直接復原。也可以從任何一份匯出的 JSON 檔完整復原。

## 資料庫版本與遷移

目前 `schemaVersion = 2`：

- v1：車輛、加油、保養單、保養明細
- v2：新增 `maintenance_plans`（保養週期）、`fuel_logs.fuel_type`、`vehicles.default_fuel_type`

**規則**：每次改動資料結構都必須 ① 提高 `schemaVersion` ② 在 `database.dart` 的 `onUpgrade` 補遷移步驟
③ 在 `test/migration_test.dart` 補「升級前後資料不遺失」的測試。

## 里程防呆（依日期判定）

加油與保養共用同一套規則，**以所選日期為準**：

- 里程不可小於「更早日期」的任何一筆（加油或保養都算）；不可大於「更晚日期」的任何一筆；可以相等
- 同一天的紀錄不互相限制；沒有更早紀錄時不可小於車輛初始里程
- 想補登舊紀錄：**先把日期改成當時的日期**，就能填當時的里程。新增保養時，里程預設帶入「該日期之前最近的里程」，
  不再固定帶最新里程
- 加油單價一律四捨五入到小數 2 位

## 油耗計算規則

以「跳停（加滿）」為區間基準，依日期、里程排序後計算：

1. **第一筆加滿**只記錄為起點，不計算油耗（油箱起始狀態未知；它之前的未加滿紀錄也忽略）。
2. 之後每一筆加滿：
   - 區間里程 = 本次里程 − 上次加滿里程
   - 平均油耗 (km/L) = 區間里程 ÷ 公升數
   - 每公里花費 = 金額 ÷ 區間里程
3. **中間有「未加滿」補油時**：公升數與金額會累計到下一次加滿一起算。
4. 平均油耗是總里程 ÷ 總公升的加權平均，不是各次油耗的算術平均。
5. 統計頁的成本指標口徑不同，已分開標示：
   - **平均油耗**：只用已完成的跳停區間，總里程 ÷ 總公升。
   - **完整區間每公里油費**：已完成跳停區間的加油金額 ÷ 區間里程。
   - **估算每公里成本**：區間油費（依區間結束日歸入期間）＋該期間保養費，÷ 區間里程。這是**估算值**，不等於該期間全部實際支出。
   - 「每月花費」長條圖才是依每筆加油 / 保養的實際日期累計。圖表最多畫最近 24 個有紀錄的月份，摘要數字仍計算整個期間。

**里程防呆**（以「日」為單位；表單會依你選的日期顯示前後紀錄的里程範圍，補登舊紀錄也不會被誤導）：里程必須大於更早日期的最大里程、小於更晚日期的最小里程；
同一天內的多筆以里程自行排序、不會互相卡住，但不可與同日另一筆里程完全相同；
沒有更早紀錄時不可小於車輛初始里程。

## 保養週期與零件歷史

- 週期由**車主自訂**（不同車款、油品的原廠規範不同，App 不預設數值）。
- 里程與天數可擇一或兩者；**任一條件先到就提醒**。
- 「目前里程」＝初始里程與所有加油 / 保養里程中的最大值，即**你最後回報的里程**，不假裝知道即時里程。
- 以項目名稱（忽略空白與大小寫）比對保養明細，找出該項目最後一次保養；完成保養後自動依新紀錄推算下一次。
- **名稱相同就視為完成一次保養**（包含檢查、補胎、工資）。若只是檢查，請用不同名稱記錄（例如「輪胎檢查」），才不會重設輪胎更換週期。
- 天數週期只接受整數；沒有設定週期的常用項目會標示為「常用項目（未啟用提醒）」。
- 提醒會在跨日、App 回到前景時重新計算。
- 保固 / 免費更換（單價 0）也會留在歷史裡。

## 環境需求

- Flutter stable（含 Dart 3.5+）
- Android：Android SDK（`flutter doctor` 會引導安裝）、JDK 17
- Windows：Visual Studio 2022，勾選「使用 C++ 的桌面開發」工作負載

> **SQLite 說明**：drift 2.32+ 搭配 `sqlite3` 3.x，SQLite 由 build hooks 在編譯時自動打包（需要 C 編譯器，
> 上述工具鏈已包含）。舊的 `sqlite3_flutter_libs` 已 EOL，本專案不再使用。

## 第一次建置（本機）

```bash
git clone <你的倉庫網址> garage_log
cd garage_log

# 1. 產生平台資料夾（只需做一次）
flutter create --platforms=android,windows --project-name garage_log --org io.github.midoyes .
python3 tools/apply_branding.py android   # 套用專屬圖示與名稱
python3 tools/apply_branding.py windows   # （Windows 上用 python）

# 2. 安裝套件
flutter pub get

# 3. 產生 Drift 程式碼（改了 tables.dart 之後也要重跑）
dart run build_runner build

# 4. 測試
flutter test
```

## 應用程式識別碼、圖示與名稱

- **Application ID 固定為 `io.github.midoyes.garage_log`**（`flutter create --org io.github.midoyes` + 專案名 `garage_log`，
  設定在 `.github/workflows/build.yml` 的 `APP_ORG` / `APP_ID`）。Android 以它辨識「同一個 App」：
  **第一次公開發行之後絕對不要再改**，否則新版不會被當成舊版的更新。CI 會檢查打出來的 APK 套件識別碼，不符就失敗。
- **圖示**：深青綠底、白色小車加橘色油滴徽章，和 Mido筆記 的圖示明顯不同。成品在 `branding/`，
  由 `tools/apply_branding.py` 在 CI 套用到 Android（含 Android 8+ 自適應圖示）與 Windows（`.ico`）。
  想換圖示：改 `tools/make_icon.py` → `pip install pillow` → `python3 tools/make_icon.py` → 提交 `branding/`。
- **名稱**：桌面與視窗標題顯示「愛車記錄」；Windows 執行檔檔名仍是 `garage_log.exe`。

## 打包 Android APK

```bash
flutter build apk --release
# 輸出：build/app/outputs/flutter-apk/app-release.apk
# 只給特定 CPU：flutter build apk --release --split-per-abi
```

- 沒有設定金鑰時，release 會用 **debug 金鑰**簽章；GitHub Actions 每次都是新環境，**每次的 debug 金鑰都不同**，
  所以用 Actions 打出來的 APK 之間**無法互相覆蓋安裝**。

### Android 簽章（務必設定，否則升級可能丟資料）


本 App 的資料只存在手機的 App 私有目錄。簽章不一致 → 無法覆蓋安裝 → 使用者只好先解除安裝 → **本機資料庫一起消失**。
所以每一版都必須用**同一把、長期保存**的金鑰簽章。一次性設定：

```bash
# 1. 建立 keystore（只做一次；檔案與密碼請備份到安全的地方，遺失就無法再發佈可覆蓋安裝的更新）
keytool -genkey -v -keystore garage_log.jks -keyalg RSA -keysize 2048 -validity 10000 -alias garage_log

# 2. 轉成 base64（Linux / macOS）
base64 -w0 garage_log.jks
#    Windows PowerShell：
#    [Convert]::ToBase64String([IO.File]::ReadAllBytes("garage_log.jks"))
```

3. 到 GitHub 倉庫 **Settings → Secrets and variables → Actions → New repository secret**，新增 4 個：

| Secret 名稱 | 內容 |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | 上一步的 base64 字串 |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 密碼 |
| `ANDROID_KEY_ALIAS` | `garage_log`（你設定的別名） |
| `ANDROID_KEY_PASSWORD` | 金鑰密碼 |

之後 CI 會自動呼叫 `tools/configure_android_signing.py` 簽章。沒設定 Secrets 時：一般 push 只顯示警告（APK 僅供測試）；
推 `v*` tag 發行則**直接失敗**，避免發出無法升級的 APK。**keystore 與 `key.properties` 絕對不要上傳到倉庫**（`.gitignore` 已排除）。

> **從舊版升級（只需做一次）**：0.2.0 以前的 APK 都是 debug 金鑰簽章，無法被正式簽章的版本覆蓋。
> 第一次換成正式簽章時，請先在舊版「設定 → 匯出全部資料」存好 JSON，解除安裝舊版、安裝新版，再「匯入」。
> 之後所有版本都可以直接覆蓋安裝、資料保留。
> 發行前請務必實測一次：安裝上一版 → 新增資料 → 直接安裝新版 APK 覆蓋 → 確認資料還在。

**簽章核對**：CI 在 `flutter build apk` 之後會執行 `aapt` / `apksigner verify --print-certs`，
在 Actions 日誌印出**套件識別碼、App 名稱與簽章憑證的 SHA-256 指紋**。請把指紋記下來（日後可核對是不是同一把金鑰）。
想讓 CI 自動比對：新增 Secret `ANDROID_CERT_SHA256`（貼上該指紋），之後指紋不符的 APK 會直接讓 CI 失敗。

> **Application ID 變更提醒**：舊的測試 APK 用的是 `com.example.garage_log`，新版是 `io.github.midoyes.garage_log`，
> Android 會把它當成**另一個 App**（兩個可以並存，不會互相覆蓋）。舊測試版若有資料，請先匯出 JSON、
> 在新版匯入，確認無誤再解除安裝舊版。

## 打包 Windows 桌面版

```bash
flutter build windows --release
# 輸出資料夾：build\windows\x64\runner\Release\
```

圖示由 `tools/apply_branding.py windows` 換成專屬的 `app_icon.ico`（本機手動建置時請先執行一次）。

**Windows release 注意事項**

1. **要發佈整個 `Release\` 資料夾**，不能只拿 `garage_log.exe`（`flutter_windows.dll`、`data\` 與外掛 DLL 都是執行必需）。最簡單是整個壓成 zip。
2. **VC++ 執行階段**：全新的 Windows 若沒有 Visual C++ Redistributable，會因缺少 `msvcp140.dll` / `vcruntime140.dll` 打不開。請使用者安裝 VC++ 2015-2022 Redistributable (x64)，或把這些 DLL 放進 `Release\` 與 exe 同層。
3. **單一安裝檔**：用 [Inno Setup](https://jrsoftware.org/isinfo.php) 打成 `setup.exe`，或用 `msix` 套件（需要簽章憑證）。
4. **SmartScreen / 瀏覽器警告**：未簽章的 exe 第一次執行會跳「Windows 已保護您的電腦」，選「其他資訊 → 仍要執行」。
   Chrome 也可能把從 Actions 下載的 zip 標成「不安全」，這是誤判；可改用 Edge / Firefox，或用 `gh run download` 下載。要根治需要程式碼簽章憑證。
5. **資料位置**：SQLite 檔在使用者的「文件」資料夾 `garage_log\garage_log.sqlite`。解除安裝不會自動清掉；要備份請用 App 內的匯出。
6. 只能在 Windows 上編 Windows 版；沒有 Windows 機器時用下面的 GitHub Actions。

## GitHub Actions

`.github/workflows/build.yml` 會在 push 時：

1. `test` job：`build_runner` → `flutter analyze --no-fatal-infos` → `flutter test`
2. `android` job：產生平台資料夾 → 編 APK → 上傳 artifact
3. `windows` job：編 Windows → 壓成 zip → 上傳 artifact
4. 推 `v*` tag（例如 `v0.2.2`）時，自動建立 Release 並附上 APK 與 Windows zip（發行版沒有設定簽章 Secrets 會失敗）
5. `test` job 會上傳 `pubspec-lock` artifact：確認建置沒問題後，把裡面的 `pubspec.lock` 放進倉庫根目錄並提交，即可固定依賴版本

## 測試

`flutter test` 會執行：油耗與里程防呆（含同日多筆、補登範圍）、保養明細驗證、週期提醒、統計彙總、
備份匯出入、孤立資料 / 空明細 / 欄位值 / 缺表檢查、`updated_at` 平手收斂、完整復原與復原後同步、自動備份清單、
v1 → v2 資料庫遷移、Repository（歸屬檢查、時間戳不倒退）、CSV、同步服務（含重試用完的衝突）、儲存按鈕防重複提交與失敗提示。

## 已知限制與刻意延後的項目

- **今日油價的來源**：使用中油公開的牌價服務，格式為作者依公開資訊撰寫，若中油改版會暫時顯示「取不到油價」，
  不影響其他功能。**「下週油價預測」尚未提供**：目前沒有官方的結構化資料來源，爬網頁文章不穩定也有授權疑慮，待確認來源後再加。

- **日期以「本地日期 00:00 的時間戳」儲存**：跨時區使用（例如出國）時，同一天的紀錄在另一個時區可能顯示成前一天。
  根治需要改成只存 `YYYY-MM-DD` 並做資料庫遷移，已列入下一版，不在此版本倉促改動資料格式。
- **無法手動回報目前里程**：目前里程取自已輸入的加油 / 保養紀錄最大值。很久沒加油時，提醒會依「最後回報的里程」計算。
  （需要新增欄位與遷移，列入下一版。）
- **時鐘大幅錯誤的裝置**：若某台裝置的時鐘被調到很久以後，它寫出的資料會在 LWW 中勝出較久。
  本機編輯一定會比該列原值新，但跨裝置的時鐘校正仍需使用者自行確保。
- **零件歷史以名稱比對**，沒有「本次完成更換」的獨立勾選欄位（見上方「保養週期與零件歷史」說明的用法）。

## 之後的路線

- Google Drive `appDataFolder` 後端（實作 `SyncBackend`，登入自己的 Google 帳號，資料只存在自己的雲端）
  ——需要先確認衝突與資料遺失的測試足夠
- 保養照片與收據（隨備份）
- 系統通知提醒（目前提醒顯示在 App 內）

## 授權

MIT，見 `LICENSE`。
