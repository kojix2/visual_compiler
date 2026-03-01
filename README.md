# visual_compiler

ローカルで Crystal の入力コードを追跡し、以下を横並びで確認するための Kemal アプリです。

- 左: 入力コード
- 中央: 段階別 AST スナップショット（タブ切替、メタ情報、前段 diff）
- 右: 生成された LLVM IR
- 中央には `Program` メタデータ（`types`, `symbols`, `unions`, `vars`, `requires` など）も表示
- Trace 時の prelude を `nano` / `prelude` で切替可能（既定: `nano`）

`astv.cr` を参考にしつつ、MVP として `parse -> canonical reparse -> codegen(llvm-ir)` の時間軸表示を実装しています。

## Setup

```bash
shards install
```

## Run

```bash
crystal run src/cli.cr
```

ブラウザで `http://127.0.0.1:3000` を開きます。

## Notes

- LLVM IR は `crystal build --prelude <選択値> --emit llvm-ir` を一時ファイルに対して実行して取得します。
- `nano` は最小 prelude のため `puts` など標準 prelude 前提のメソッドは使えません（必要時は UI で `prelude` を選択）。
- このツールはローカル利用を想定しています（インターネット公開は想定外）。
- `Program` メタデータは内部的に `crystal eval -Di_know_what_im_doing -Dwithout_libxml2` を別プロセス実行して取得します。
- compiler利用の依存として `nano`, `markd`, `reply` を追加済みです。
