# atomcam_tools

このツールキットは、ATOMCam/ATOMCam2/AtomSwing/WyzeCamV3の機能を拡張するツール及びスクリプトをまとめたものです。

[mnakada さんの atomcam_tools](https://github.com/mnakada/atomcam_tools) を fork しています。
mnakada さんと オリジナルの作者 bakueikozo さんに深く感謝申し上げます。

利用にあたって、カメラメーカへの問い合わせなどは厳に慎んでください。
それ以外は自由に利用できますが、悪用または他人へ迷惑をかけた場合の責任は、コードを利用した者が負うべきものとします。

セキュリティに関しては、オリジナルと同様の注意事項がありますのでfork元を必ず参照してください。

## 追加・修正している機能
- [Fix] hostname取得後のパイプがcloseされずゾンビプロセスとして残る問題を修正.
- [Fix] timelapse_hook_geocentric.sh でカメラ移動のリトライと待ち時間が機能していない問題を修正.
- [Fix] 日付をまたぐ録画スケジュール（例: 17:30〜06:30）で常時録画・検知録画が保存されない問題を修正.
- [Fix] SDカード上の atom_root.squashfs がサイズでしか比較されず、純正ファームの rootfs が更新されても作り直されない問題の修正.
- [Feature] 時刻合わせを確実に行うため、ntpd が停止したときに自動で再起動する機能の追加.
- [Feature] Main HD の映像に入る日時表示（タイムスタンプ）の大きさを選べる機能の追加.
- [Feature] 静止画（JPEG）の画質を高画質に設定できる機能の追加.
- [Feature] 機能を拡張した際の動作確認を容易にするため、実機用スモークテストを追加.
- [Feature] Web UIにカスタムバージョンを表示.
- [Feature] 時刻を指定して、撮影条件と方向を変える機能(Preset Schedule)の追加.
- [Feature] ゲインと露出を読むコマンドの追加.
- [Feature] 夜の星空画像のために露出を100ms（10fpsの1フレーム相当）にする設定の追加.
- [Feature] JPEGストリームをMJPEGのmp4で保存する設定の追加.

主としてATOMSwingを対象にして、昼は特定の方向に向けてカラーでタイムラプスを撮影、夜になったら空に向けて露出を最大にしてコントラストを調整し、流星撮影を行うことを目的に機能を追加しています。

## 動作確認バージョン

 このforkは以下のATOMCamのVersionで動作確認しています。更新した場合機能が使えなくなることもあるのでご注意ください。

 ATOMSwing 4.37.1.166, 4.37.1.180

## ファームウェアの更新について

以下は自分でビルドしたatomcam_tools.zipに、SD-Cardを抜かずに入れ替える手順です。

**Web画面のatomcam_toolsのupdate機能はGitHubのLatestイメージをダウンロードして入れ替えます。自分でビルドしたイメージを使っている場合は、その変更が失われるので使わないでください。**

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
