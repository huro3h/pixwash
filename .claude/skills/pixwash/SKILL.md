---
name: pixwash
description: Pixwash(写真のモザイク・サイズ変更・メタデータ削除をまとめた自分用 iOS アプリ)を改修するときに使う。画像処理の流れ、座標の持ち方、ビルドとシミュレータでの確認手順をまとめている。
---

# pixwash

## 前提・制約

- SwiftUI + XcodeGen。App Store では配布せず、無料 Apple ID の Personal Team で実機に入れる
  (プロファイルは7日で失効して入れ直し、1端末に入れられる自作アプリは3つまで)。
- 署名値(`DEVELOPMENT_TEAM`、`PRODUCT_BUNDLE_IDENTIFIER`)は git 管理外の `Config/Local.xcconfig` に書き、
  `Config/App.xcconfig` が `#include?` で読む。**`project.yml` に `PRODUCT_BUNDLE_IDENTIFIER` を書かない**
  (ターゲット設定は xcconfig より強く、Local の値が効かなくなる)。
- **public リポジトリ**。アカウント固有の値・動作確認に使った実在の写真や位置情報をコミットしない。
- 写真ライブラリは **読まない・追加だけ**。読み込みは `PhotosPicker`(許可不要)、保存は
  `PHPhotoLibrary.requestAuthorization(for: .addOnly)`。Info.plist には `NSPhotoLibraryAddUsageDescription` だけ。
- Swift 6 + `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`。画像処理側の型・関数は **`nonisolated` を付ける**
  (付けないと MainActor になり、`@concurrent` の関数から使えない)。

## ビルドと確認

```sh
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Pixwash.xcodeproj -scheme Pixwash \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/DerivedData build
```

- `xcode-select` が CommandLineTools を向いている環境では、CLI で `DEVELOPER_DIR` を付ける。
- 実機へのインストール:
  1. `xcrun devicectl list devices` で `available (paired)` の端末の Identifier を見る。
  2. `xcrun devicectl device info details --device <Identifier> --json-output x.json` で
     `result.hardwareProperties.udid` を取る(devicectl の Identifier と UDID は別物)。
  3. `xcodebuild ... -destination "id=<UDID>" -allowProvisioningUpdates -allowProvisioningDeviceRegistration build`
     (`generic/platform=iOS` だとプロファイルに端末が入らず、インストールで 0xe8008012 になる)
  4. `xcrun devicectl device install app --device <Identifier> build/DerivedData/Build/Products/Debug-iphoneos/Pixwash.app`
  5. `xcrun devicectl device process launch --terminate-existing --device <Identifier> <bundle id>`
     (bundle id は `Local.xcconfig` 次第なので、ビルドした `Pixwash.app/Info.plist` の `CFBundleIdentifier` から取る)
- **リリース(`/release`)では実機へのインストール・起動まで行う。** バージョンは `project.yml` の `MARKETING_VERSION`
  (タグと同じ番号。`CURRENT_PROJECT_VERSION` は 1 のまま)。端末がつながっていなければ、つなぐ・ロックを外すよう頼む。
- シミュレータでは写真ピッカーを自動操作できないので、**DEBUG ビルドは環境変数 `PIXWASH_OPEN` の画像を起動時に開く**
  (`RootView`)。`simctl launch` には `SIMCTL_CHILD_` を付けて渡す:
  `SIMCTL_CHILD_PIXWASH_OPEN=/path/to/src.jpg xcrun simctl launch --terminate-running-process <device> <bundle id>`
  → `xcrun simctl io <device> screenshot x.png`。
- 画像処理だけなら macOS で直接確かめられる: `Models/*.swift` と `Services/ImageDecoder.swift`・`ImageExporter.swift` を
  テスト用の `main.swift` と一緒に
  `swiftc -swift-version 6 -default-isolation MainActor -enable-upcoming-feature NonisolatedNonsendingByDefault` で
  コンパイルする。`main.swift` では **`DispatchSemaphore` で待たず top-level `await` を使う**
  (top-level は MainActor なので、セマフォで main を塞ぐと Task が走らずに固まる)。

## 画面の構成

- 写真を選ぶ前から編集画面を出す(ユーザーの希望、2026-11-03。白い画面に「写真を選ぶ」だけを出していた)。
  写真の場所が「写真を選ぶ」の `PhotosPicker` になり、下の操作部分も先に設定できる。選んだ後は左上のボタンで選び直す。
- そのため `EditorModel` は1つを使い続け、`photo` は後から `open(_:)` で入る。選び直すと線・加工済み画像・書き出し結果は消えるが、
  隠し方・強さ・サイズ・メタデータの設定は引き継ぐ(形式だけは元の写真に合わせて JPEG / PNG を選び直す)。
- 加工済み画像・書き出しは時間がかかるので、終わったときに写真が選び直されていたら捨てる(`LoadedPhoto.id` で比べる)。

- **署名の期限の表示**(2026-11-03): ヘッダーの真ん中に、期限の日時「11/10 22:05」と残り「6日23時間」を小さく2行で出す(`Support/ProvisioningExpiry.swift`。「期限」などの言葉は付けない)。
  アプリに同梱される `embedded.mobileprovision` の `ExpirationDate` を読む(CMS の中の plist は平文なので `<?xml`〜`</plist>` を切り出す)。
  シミュレータには同梱されないので出ない。**aozora と pixwash に同じファイルを置いている。直すときは両方直す。**
  期限の自動延長は別プロジェクトの ios-reinstall(USB でつなぐと、残り6日未満なら最新のタグから作り直して入れ直す)。

## 拡大と塗りの操作(ZoomableCanvas)

- **1本指で塗り、2本指で拡大・移動**(ユーザーと相談して決めた、2026-11-03)。モード切り替えのボタンは置かない
  (拡大して塗る・少し動かす・また塗る、のたびに押すことになるため)。ダブルタップ・長押しも使わない(1本指は塗りに使うので、点を打つタップと区別できない)。
- SwiftUI のジェスチャは触れている指の本数を区別できないので、`UIScrollView`(`CenteringScrollView`)に `UIHostingController` で
  SwiftUI の中身(`CanvasLayers`)を載せている。`panGestureRecognizer.minimumNumberOfTouches = 2` で移動を2本指に限り、
  塗りは自作の `SingleTouchGestureRecognizer` で受ける(`UIPanGestureRecognizer` は動き出すまで待つので、触れた瞬間から線を引けない)。
  `delaysContentTouches = false` も同じ理由。塗りのタブ以外では1本指でも移動できる。
- **2本目の指が触れたら塗りかけの線を捨てる**(`.cancelled`)。2本の指は同時には触れないので、先に触れた指で短い線が引かれてしまうため。
  ピンチと同時に認識できるよう、`shouldRecognizeSimultaneouslyWith` は常に true。
- 塗りの位置は `location(in: host.view)` で、拡大中でも拡大前の座標で取れる。**太さは画面上の大きさ**で、`brushSize / zoomScale` を写真に対する太さにする
  (拡大して塗ると細い線になる)。粗さ・強さは写真に対する大きさなので、拡大しても変わらない。
- 全体表示のときは `CenteringScrollView.layoutSubviews` で余白(`contentInset`)と位置を合わせて真ん中に置く。拡大中は右上に「全体表示」ボタン。
- `scrollViewDidZoom` は `updateUIView` の中の `setZoomScale` からも呼ばれるので、SwiftUI の状態(`zoomScale`)は `DispatchQueue.main.async` で変える。
- 表示用の画像は長辺 2048px のままなので、大きく拡大すると表示はぼやける(書き出しには影響しない)。最大 8 倍。

## 画像処理の流れ

1. `ImageDecoder.decode`: PhotosPicker から `preferredItemEncoding: .current` で元のファイル(HEIC なら HEIC)を
   Data で受け取り、`CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceCreateThumbnailWithTransform` で
   **Orientation を画素に焼き込んだ** 画像を作る(最大サイズを元の長辺にすれば縮まない)。
   元の解像度の `full` と、表示用に長辺 2048 に縮めた `preview` の2枚を持つ。
2. 画面(`MosaicCanvas`): `preview` の上に、`preview` をモザイクにした画像を **線の形の Canvas でマスクして** 重ねる。
   なぞっている間に合成画像は作らない(軽さのため)。
   **なぞっている最中の線(`current`)はマスクに入れず、半透明の黄色いペンの線として上に重ねる。** 指を離して
   `strokes` に入った時点でモザイクに変わる(ユーザーの希望、2026-11-03。直接モザイクが出るより、どこを塗ったか分かりやすい)。
   ペンの線は透明度レイヤー(`beginTransparencyLayer`)の中で描く。線が自分と重なっても濃くならないようにするため。
3. 書き出し(`ImageExporter.export`、`@concurrent`): `full` にモザイク合成 → 縮小 → エンコード → 一時フォルダに書く。
   設定が変わるたびに 0.4 秒待ってから `EditorView` の `.task(id: exportKey)` で書き出し、ファイルサイズの表示と
   共有ボタンに使う。保存ボタンは同じ結果を使い回す(`EditorModel.export` が `ExportKey` で判定)。

## 座標とモザイク/ぼかしの強さ

- `MosaicStroke` の座標・太さは **「画像の長辺 = 1」** の単位。表示サイズにも元画像にも長辺を掛けるだけで同じ線になる。
  線を描く処理(`MosaicStroke.draw(in:unit:)`)は画面の Canvas(`withCGContext`)と書き出しのマスクで共通。
- 隠し方は `ConcealEffect`(モザイク `CIPixellate` / ぼかし `CIGaussianBlur` と、強さ `fraction`)。強さも長辺に対する割合
  (モザイクはブロックの大きさ、ぼかしは半径)なので、縮小した `preview` と `full` で見た目が揃う。範囲は `EditorModel.effect`。
  - モザイクは 0.02〜0.06(4032px で 80〜240px)。最初は 0.008〜 にしていたが、縮めて表示するとモザイクに見えず、
    細かいモザイクは要らないとも言われて 0.03 まで引き上げ、実機で使ってみて「少し細かいのも欲しい」と 0.02 に戻した(2026-11-03)。
    下限を動かすときは、ユーザーに実機で見てもらうのが早い。ぼかしは 0.01〜0.04。
- **隠し方は線ごと**(`MosaicStroke.effect`)。最初は1枚のモザイク画像を全部の線で共有していたため、粗さを変えると
  前の線まで一緒に変わり「変えてからなぞっても粗さが変わらない」と言われた(2026-11-03)。
  加工済みの画像は隠し方ごとに作る(画面用は `EditorModel.concealedPreviews`、書き出しは `compose` の中で)。
  種類が増えすぎないよう、強さのスライダーは 0.1 刻み。段階があると分かるよう、iOS 26 の `Slider(..., step:, label:, tick:)` で
  選べる位置に目盛りを出している(見た目はつまみの下の小さな点。iOS 標準の描き方で、形は変えられない)。
- 描くときは `MosaicRun.runs(of:)` で「隠し方が同じで続いている線」ごとにまとめ、まとまりごとに加工済みの画像を切り抜いて
  順に重ねる。隠し方だけでまとめると、重なったときに後から引いた線が下になることがあるため。
- 強さの確認に縞模様などの単純な画像を使わない。どのブロックの大きさでも平均すると同じ色になり、違いが見えない。
- 書き出しの合成は、線を **グレースケールのマスク画像** に描いて `clip(to:mask:)` で切り抜く(まとまりごとに `saveGState` / `restoreGState`)。
  線の輪郭のパスを足し合わせて clip すると、重なった部分の向き次第で穴が空くため。
- フィルタは外側を `clampedToExtent()` で埋めてから掛ける(しないと端が透明と混ざって暗くなる)。

## サイズ変更

- 切り替えの並びは「元のまま / 長辺 / 割合」で、既定は長辺 1920px(ユーザーの希望、2026-11-03)。並びは `ResizeMode` の case の順。
- 長辺は拡大しない(元より大きい値なら元のまま。プリセットのボタンも元の長辺以上は押せない)。

## メタデータ

- 削除: `CGImageDestinationAddImage` に渡した辞書にない項目は書き込まれない。Orientation=1 と JPEG の画質だけ渡す。
  書き出し結果に残るのは ColorSpace・PixelX/YDimension・Orientation だけ(macOS での確認、2026-11-03)。
- 残す設定のときは、元から Exif・TIFF・GPS・IPTC を写し、Orientation を 1、PixelX/YDimension を書き出し後の値に直す。
- 保存は `PHAssetCreationRequest.addResource(with: .photo, data:)` で **書き出したバイト列をそのまま** 渡す
  (UIImage 経由だと iOS が再エンコードする)。写真アプリ上の日付は保存した日時になる。
- **ファイル名はランダム**(紛らわしい文字を除いた英小文字と数字で、長さも 16〜30 文字からランダム。`ImageExporter.randomFileName`)。
  乱数は `SecRandomCopyBytes`(ユーザーの希望。剰余の偏りは引き直しで除く)。共有するファイルも、写真ライブラリに保存するときの
  `PHAssetResourceCreationOptions.originalFilename` も同じ名前。指定しないと写真ライブラリが連番の「IMG_6780」を付け、
  時期を推測できてしまう(ユーザーの希望、2026-11-03)。最初は共有ファイルの名前に書き出し日時を入れていたので、日時を名前に入れない。
- 透過のある PNG を JPEG にすると透明部分が黒くなるので、元が PNG なら形式の既定を PNG にしている。

## アイコン

`design/icon.svg`(青 `#1A73E8` に白い 3×3 のモザイクタイル)から
`rsvg-convert -w 1024 -h 1024 -b '#1A73E8' design/icon.svg -o Pixwash/Assets.xcassets/AppIcon.appiconset/icon-1024.png`。
