# AudioRouting

アプリごとの音声出力先を、メニューバーから切り替える macOS アプリです。
システム全体の出力先はそのままに、「Spotify はヘッドホン、Zoom はスピーカー」のようにアプリ単位で振り分けます。

- macOS 14.2 以上 / Apple Silicon（arm64）
- メニューバー常駐（Dock には出ません）
- Core Audio の Process Tap → Aggregate Device → IOProc で、アプリの音を指定デバイスへ流します（元の出力はミュート）

## 使い方

1. メニューバーのスピーカーアイコンを開く
2. 初回は「アクセスを許可…」から「システム音声の録音」を許可する
3. 「音を出しているアプリ」の各アプリで、出力先（「既定の出力」または接続中のデバイス）を選ぶ

- 一覧に出るのは、いま音を出しているアプリと、出力先を保存済みで起動中のアプリです。
- ブラウザなどのヘルパープロセス（Safari の `com.apple.WebKit.GPU`、Chrome Helper など）は親アプリにまとめて扱います。
- 出力先のデバイスが外れると既定の出力に戻り、再接続すると保存した設定どおりに戻ります。
- 選んだデバイスがシステムの既定出力と同じときは、Tap を作りません（そのまま既定出力で鳴ります）。
- 「ログイン時に起動」はメニューで切り替えます（初期値はオフ）。
- 設定は UserDefaults の `AppRoutingSettings` に保存されます（バンドルID → デバイスUID）。

## ビルドとインストール

必要なもの: Xcode、XcodeGen（`tools/xcodegen/` に置く。`.gitignore` 済み）、署名用の証明書（下記）

```bash
scripts/build-app.sh            # Release ビルド → /Applications/AudioRouting.app に入れ替え
scripts/build-app.sh ~/Applications   # 入れる場所を変える場合
```

`project.yml` が正で、`AudioRouting.xcodeproj` は生成物です（`tools/xcodegen/bin/xcodegen generate`）。

### 署名

「システム音声の録音」の許可はアプリの署名に結びつきます。ad-hoc 署名だとビルドのたびに許可が外れるため、
ログインキーチェーンの自己署名証明書 **AudioRouting Local Signing**（種類: コード署名、コード署名を「常に信頼」）で署名しています。
証明書は `/System/Library/CoreServices/Certificate Assistant.app` で作れます。確認:

```bash
security find-identity -v -p codesigning
```

## テスト

```bash
xcodebuild test -project AudioRouting.xcodeproj -scheme AudioRouting -destination 'platform=macOS,arch=arm64' -derivedDataPath build
```

同じフォルダで複数の xcodebuild を同時に走らせないでください（`build/` と Tap の数が衝突します）。

- 単体テスト: Core Audio を `AudioSystem` プロトコルの裏に隠し、モックで RoutingManager・設定保存・デバイス切断/再接続・アプリ終了・権限・IOProc のバッファコピーなどを検証
- 結合テスト（`IntegrationTests`）: 実 Core Audio で `afplay` の音を Tap → Aggregate → 出力へ流し、音が届くことと Tap/Aggregate が残らないことを確認。権限や出力デバイスがない環境では `XCTSkip`

### セルフテスト（インストール済みアプリで実行）

```bash
open -W -n -a /Applications/AudioRouting.app --args --self-test /tmp/audiorouting-self-test.txt
cat /tmp/audiorouting-self-test.txt
```

インストール済みアプリ自身の許可で、`afplay` の検出、ルーティング、音が届くこと、後始末を確認します。
既定以外の出力デバイスがつながっていれば、そのデバイスへのルーティングも確認します。

## 既知の制約

- 権限の確認・要求に非公開 API（TCC の `TCCAccessPreflight` / `TCCAccessRequest`）、ヘルパーの親アプリ判定に
  `responsibility_get_pid_responsible_for_pid` を使っています。自分の Mac で使う前提で、App Store には出せません。
- 1つのアプリは1つの出力デバイスにのみ流せます。アプリごとの音量・ミュート、入力（マイク）のルーティングはありません。
- バンドルIDのないコマンドラインツール（`afplay` など）はメニューに出ません。
- 停止直後は Core Audio の一覧に Tap/Aggregate が少し残って見えます（削除自体は成功しており、すぐ消えます）。
