# atomcam_tools

このツールキットは、ATOMCam/ATOMCam2/AtomSwing/WyzeCamV3の機能を拡張するツール及びスクリプトをまとめたものです。

[mnakada さんの atomcam_tools](https://github.com/mnakada/atomcam_tools) を fork しています。
現在の開発者である mnakada さんと オリジナルの作者 bakueikozo さんに深く感謝申し上げます。

利用にあたって、カメラメーカへの問い合わせなどは厳に慎むべきです。
それ以外は自由に利用できますが、悪用または他人へ迷惑をかけた場合の責任は、コードを利用した者が負うべきものとします。

セキュリティに関しては、オリジナルと同様の注意事項がありますので fork 元の注意事項を必ず参照してください。

## 追加・修正している機能
- [Fix] hostname取得後のパイプがcloseされずゾンビプロセスとして残る問題を修正.
- [Fix] timelapse_hook_geocentric.sh でカメラ移動のリトライと待ち時間が機能していない問題を修正.
- [Fix] SDカード上の atom_root.squashfs がサイズでしか比較されず、純正ファームの rootfs が更新されても作り直されない問題の修正.
- [Fix] 日付をまたぐ録画スケジュール（例: 17:30〜06:30）で常時録画・検知録画が保存されない問題を修正.
- [Fix] RTSP で確保されるバッファメモリを圧縮に見合ったサイズに削減.
- [Fix] Web 画面で設定を保存すると、hack.ini の CONFIG_VER が 1.0.1 に戻る問題の修正.
- [Feature] 時刻合わせを確実に行うため、ネットワークの起動を待ち、ntpd が自動で再起動する機能の追加.
- [Feature] 機能を拡張した際の動作確認を容易にするため、実機用テストの機能を追加.

- [Refine] go2rtcのメモリ利用量削減.
- [Refine] Sambaのメモリ利用量削減.
- [Refine] cronのログ改善
- [Feature] Main HD のタイムスタンプの大きさを選べる機能の追加.
- [Feature] 静止画（JPEG）の画質を高画質に設定できる機能の追加.

（以上は本家にマージされました。ありがとうございます!）

- [Fix] (Swing)再起動やモーターの反転の際に位置がずれる問題の修正.
- [Fix] Web画面でSDカードへの保存設定を書き込んだ時の問題の修正.
- [Fix] 直接記録した常時録画を移すときの一時ファイルの問題の修正.
- [Feature] JPEGストリームをMJPEGのmp4で保存する設定の追加.
- [Feature] ゲインと露出を読むコマンドの追加.
- [Feature] 夜の星空撮影向けに、露出が最大となる100ms（10fpsの1フレーム相当）にする設定の追加.
- [Feature] Web UIにカスタムバージョンを表示.
- [Feature] 時刻を指定して、撮影条件と方向を変える機能(Preset Schedule)の追加.

主としてATOMSwingを対象にして、昼は特定の方向に向けてカラーでタイムラプスを撮影、夜になったら空に向けて露出を最大にしてコントラストを調整し、流星撮影を行うことを目的に機能を追加しています。

オリジナルにバグが見つかった場合は、随時PRを送っていきます。

## 機能拡張されたwebインターフェース
カメラ画像：　タイムスタンプを小さくでき、星空の撮影で感度をMAX （3500ライン）まで上げることができます。
<img width="1721" height="1108" alt="カメラ画像" src="https://github.com/user-attachments/assets/95fb947f-5909-4df5-8566-908b2b70a2fa" />

カメラ設定：　露出をMaxにできます。
<img width="1716" height="1108" alt="カメラ設定" src="https://github.com/user-attachments/assets/4dc3da5d-acb1-4e58-bdc7-263c89d445e0" />

スケジュール機能：　時間とコマンドを指定して、動作をスケジューリングできます。タイムラプスや録画、再起動のスケジュールも一括して表示させることができ、設定変更時に干渉があると警告を表示します。
<img width="1718" height="1108" alt="スケジュール" src="https://github.com/user-attachments/assets/870eb26e-05e2-4f22-9591-821a74103dee" />

システム設定画面を拡張して、タイムスタンプの大きさと jpeg 画像のクオリティを変更できるようにしました。
<img width="1712" height="1108" alt="システム設定" src="https://github.com/user-attachments/assets/a060be19-6f94-4d0a-b86f-58706dcd1a49" />

## 動作確認バージョン

 このforkは以下のATOMCamのVersionで動作確認しています。更新した場合機能が使えなくなることもあるのでご注意ください。

 ATOMSwing 4.37.1.182

## ファームウェアの更新について

以下は自分でビルド、またはこのリポジトリから取得したatomcam_tools.zipに、SD-Cardを抜かずに入れ替える手順です。

**Web画面のatomcam_toolsのupdate機能は本家GitHubのLatestイメージをダウンロードして入れ替えます。自分でビルドしたイメージを使っている場合は、その変更が失われるので使わないでください。**

### 1. ビルド

```sh
make build-local   # ビルド用のコンテナが起動済みのとき（未起動ならmake）
```

`atomcam_tools.zip`が生成されます。origin/mainに含まれないコミットからビルドすると、Versionは`2.5.19.custom_<コミット>`のようになります。

### 2. 現在のファームウェアのバックアップ

戻せるように、SD-Card上の現在のファイルをPCに保存しておきます。

```sh
mkdir -p backup/<現在のVersion>
for f in factory_t31_ZMC6tiIDQN rootfs_hack.squashfs; do
  ssh root@atomcam.local "cat /media/mmc/$f" > backup/<現在のVersion>/$f
done
```

現在のVersionはWeb画面か`cat /etc/atomhack.ver`で確認できます。

### 3. 更新ファイルを置く

`atomcam_tools.zip`をSD-Cardの`update`フォルダ（カメラからは`/media/mmc/update/`）に置きます。

```sh
ssh root@atomcam.local 'cat > /media/mmc/update/atomcam_tools.zip && sync' < atomcam_tools.zip
```

### 4. 再起動

Web画面のメンテナンスの再起動か、次のコマンドで再起動します。録画を止めてsyncしてから再起動されます。

```sh
curl -s -X POST -H 'Content-Type: application/json' -d '{"exec":"reboot"}' http://atomcam.local/cgi-bin/cmd.cgi
```

起動時にinitramfsが更新ファイルを処理します。

- zipからは`factory_t31_ZMC6tiIDQN`と`rootfs_hack.squashfs`だけが展開されます。`authorized_keys`と`hostname`は変更されません。
- それぞれファイルサイズがヘッダーの値と一致したときだけ入れ替えます。一致しないファイルは`update`フォルダに残ります。
- rootfsを入れ替えるとswapファイルが作り直されます。kernel（factory_t31_ZMC6tiIDQN）を入れ替えたときはもう一度再起動します。

ATOMSwingでは、再起動を指示してから1分半程度でsshにつながりました。

### 5. 確認

```sh
ssh root@atomcam.local cat /etc/atomhack.ver   # 新しいVersionになっていること
make test-device                               # tests/device/smoke.sh
```

`make test-device`で`ARGS=-d`を付けると、停止を伴うテストも実行します。

### 戻す場合

バックアップした`factory_t31_ZMC6tiIDQN`と`rootfs_hack.squashfs`を`/media/mmc/update/`に置いて再起動します。zipにまとめなくても、ファイルごとに同じ手順で入れ替わります。

### Copyright

ライセンスは、私が独自に拡張したものを含めて全て原著者の取り扱いに準じます。

詳しくはLICENSEファイルを参照してください.
