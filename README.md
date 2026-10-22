# TVerPiP

TVerの動画を、ホーム画面へ戻ったときにPicture in Picture（PiP）で継続再生できるようにするパッチです。

> [!IMPORTANT]
> このリポジトリにTVer本体や復号済みipaは含まれません。ビルド済みipaを第三者へ再配布しないでください。

## Features

- ホーム画面への遷移でPiPを開始
- PiP中のバックグラウンド音声
- PiPおよびコントロールセンターの再生・一時停止・15秒送り戻し
- PiP終了後のバックグラウンド処理を自動停止
- TrollStoreおよび通常のサイドローディングに対応

## Requirements

- macOS
- XcodeとCommand Line Tools
- Swift（Xcodeに同梱）
- `zip`と`unzip`
- 利用者自身が適法に用意した復号済みTVer ipa

TVer `7.2.4`とiOS `17.3.1`で動作確認しています。

## Building TVerPiP

### Local Setup

TrollStoreとサイドローディングで同じipaを使用します。

```sh
git clone https://github.com/awazustamin/TVerPiP.git
cd TVerPiP
chmod +x ./build.sh
./build.sh /path/to/decrypted-tver.ipa
```

引数を省略する場合は、復号済みipaを次の名前で配置します。

```sh
packages/jp.hamitv.hamitvapp1.ipa
```

```sh
./build.sh
# Output: packages/TVerPiP.ipa
```

### GitHub Actions

1. このリポジトリをForkします。
2. **Actions**タブでWorkflowを有効化します。
3. **Build TVerPiP**を選択して**Run workflow**を押します。
4. 復号済みipaのHTTPS URLを入力します。
5. 必要に応じて、入力ipaのSHA-256を指定して実行します。

完成したipaはWorkflow Artifactとして1日だけ保持されます。同じipaをTrollStoreまたはサイドローディングで利用できます。Workflowの入力履歴に残っても問題のない一時URLを使用してください。ビルド済みipaをGitHub Releaseへ公開しないでください。

## Install

### TrollStore

生成した`TVerPiP.ipa`をTrollStoreで開いてインストールします。

### Sideloading

生成した`TVerPiP.ipa`を再署名してインストールします。

## Usage

1. TVerで動画を再生します。
2. 再生したままホーム画面へ戻ります。
3. PiPが自動的に開始します。

## Limitations

- iOSやTVerの更新で動作しなくなる可能性があります。
- TVer更新後は、新しい復号済みipaへパッチを再適用する必要があります。

## Legal

このプロジェクトは教育・個人利用を目的としたパッチコードのみを提供します。TVerおよび関連する名称・商標は各権利者に帰属します。本プロジェクトは株式会社TVerその他の権利者とは無関係です。利用地域の法律、サービス利用規約、コンテンツ権利を遵守してください。

ライセンスは[MIT License](LICENSE)です。このライセンスは本リポジトリのパッチコードにのみ適用され、TVerアプリやコンテンツには適用されません。
