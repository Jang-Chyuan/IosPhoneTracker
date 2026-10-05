# IosPhoneTracker

獨立 iPhone／iPad 專案，將 `C:\Dog_Reactive\PhoneTracker` 的定位與歷史功能移植為 Swift／SwiftUI。最低 iOS 16，專案採 Swift 5 語言模式，沒有第三方套件。使用 Apple MapKit，無須 Google Maps API 金鑰。

## 已加入的功能

- 即時位置：手機位置、精度圓、拖動地圖後停止跟隨，再按「即時位置」恢復跟隨。
- 開始／停止記錄：保存使用者的停止偏好；重新開啟 App 時，曾啟動且仍有定位權限可恢復記錄。
- 背景定位：Core Location 與 `UIBackgroundModes=location`，不依賴畫面計時器寫入資料。
- 保存速度規則：≤ 10 km/h（含靜止）每 30 秒、> 10 且 ≤ 20 km/h 每 5 秒、> 20 km/h 每秒；未知速度每 30 秒。使用原始速度控制儲存間隔。
- 定位品質：低速精度 ≤ 30 m、高速 < 50 m，拒收過期／倒序／無效／不合理跳點；三點平滑與高速最新點 90% 權重；靜止確認及離開遲滯。
- SQLite：Application Support 私有資料庫，WAL、序列寫入、同一交易保存與修剪，最多 80,000 筆，超過刪除最舊記錄。保留原始與平滑位置、精度、速度、session 與移動狀態。鎖屏後可存取，資料目錄排除備份。
- 歷史軌跡：1／3／6 小時獨立按鈕（預設 6），指定開始／結束日期時間（最長 240 小時），手機本地時區。
- 歷史記錄最多查詢最近 8,000 筆；繪圖最多 4,000 點／120 段；不同 session、兩分鐘中斷、無效座標及日期變更線會斷開，不刪除未繪製的資料。
- 回放：播放／暫停，每秒前進一分鐘、時間滑桿、完整軌跡。
- 橘色三角游標：長按拖動，放開後吸附到實際記錄點；只在地圖外顯示 `HH:mm:ss`，沒有遮住軌跡的文字框。
- 匯出地圖：PNG，繪入歷史路線或即時位置與三角游標，資訊放在圖片下方，透過 iOS 分享選單「儲存到檔案」或分享。保留地圖原有署名區域。

## iOS 與 Android 的差異

iOS 的「背景執行」按鈕會請求／說明背景定位權限，使用者需自行返回主畫面或鎖屏。**不使用 `exit(0)` 或私有 API 主動關閉 App**。iOS 沒有 Android 常駐前景服務通知，背景定位會顯示系統的位置使用提示。

定位更新頻率由 iOS 控制，30／5／1 秒是最小保存間隔，不保證系統每秒提供合格定位；沒有新合格定位時不補寫。使用者從最近使用畫面強制關閉 App 後，不承諾繼續定位或自動重啟。建議在 iPhone 設定允許「永遠」定位及「精確位置」。

目前保存平滑管線座標，沒有 Android 地圖動畫中間座標；Apple 地圖樣式也與 Google 地圖不同。既有 Android SQLite 不會自動轉移到 iPhone。App 圖示與 App Store 素材尚未製作，App Store 上架前需補齊。

Apple 參考：

- [背景位置更新](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background)
- [CLLocationManager](https://developer.apple.com/documentation/corelocation/cllocationmanager)
- [MapKit 地圖快照](https://developer.apple.com/documentation/mapkit/mkmapsnapshotter)
- [隱私 API 使用理由](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)

## 在 Mac 開啟與安裝

1. 複製整個 `IosPhoneTracker` 資料夾到 Mac，安裝 Xcode 與所需 iOS SDK。
2. 直接開啟 **`PhoneTracker.xcodeproj`**。已附共享 `PhoneTracker` scheme 與 `PhoneTrackerTests` 測試 target，不需另裝專案產生工具。
3. 選擇 PhoneTracker target → Signing & Capabilities → 設定自己的 Team。預設 Bundle ID 為 `com.jangchyuan.IosPhoneTracker`，需要時改成自己可簽署的唯一 ID。
4. 先選 iPhone 模擬器，按 Run；再使用 Product → Test 或 `⌘U` 執行測試。
5. 用 USB／已配對無線方式連接 iPhone，按需要啟用 Developer Mode，選實機按 Run。首次允許定位並開啟精確位置，再按「背景執行」依系統提示設定權限。
6. 使用 TestFlight 發布需要 Apple Developer Program，之後在 Xcode Organizer 上傳 App Store Connect。

可在 Mac 終端先列出可用模擬器：

```sh
xcodebuild -list -project PhoneTracker.xcodeproj
xcodebuild -showdestinations -project PhoneTracker.xcodeproj -scheme PhoneTracker
```

選擇前一步的 iOS Simulator ID 執行：

```sh
xcodebuild test -project PhoneTracker.xcodeproj -scheme PhoneTracker \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' CODE_SIGNING_ALLOWED=NO
```

## 驗證狀態

目前在 Windows 建立專案。已檢查專案檔案引用、XML／plist 格式，並使用 SQLite 執行真實 schema、80,000 筆修剪及歷史排序驗證。**Windows 沒有 Xcode／iOS SDK，所以尚未編譯 Swift iOS target、執行 XCTest 或在 iPhone 驗證；不能將靜態檢查視為編譯通過。**

已附 XCTest：儲存頻率與速度邊界、過期與品質拒收、靜止鎖定及離開、歷史斷點、SQLite 修剪與 8,000 筆歷史上限。

實機仍需驗證：拒絕與允許定位、精確位置關閉、背景／鎖屏至少 5 分鐘、停止後不再新增、原始速度切換間隔、三角游標拖動、指定時段、回放、PNG 儲存及分享。

## 檔案

- `PhoneTracker/TrackingCore.swift`：平台無關的定位與軌跡規則。
- `PhoneTracker/LocationStore.swift`：SQLite schema、寫入、修剪與查詢。
- `PhoneTracker/Tracker.swift`：Core Location、儲存佇列與 UI 狀態。
- `PhoneTracker/TrackingMap.swift`：原生 MapKit 地圖、路線、游標。
- `PhoneTracker/ContentView.swift`：操作介面與時段／回放控制。
- `PhoneTracker/MapExporter.swift`：地圖 PNG 合成及分享。
- `PhoneTracker/Info.plist`、`PrivacyInfo.xcprivacy`：定位用途、背景能力與隱私理由。
- `PhoneTrackerTests/TrackingTests.swift`：XCTest。
- `scripts/Generate-XcodeProject.ps1`：Windows 上重建 Xcode 專案設定，不是 Mac 編譯步驟。
- `scripts/Verify-Project.ps1`：Windows 可執行的結構與 SQLite 驗證。
