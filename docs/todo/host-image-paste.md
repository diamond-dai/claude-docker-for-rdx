# Host Image Paste (保留中の検討案)

> ステータス: **未実装 / 保留**
> 現状: docker コンテナ内の claude にホスト側からの image paste はできない。
> コンテナは host のクリップボードに触れないため、⌘V してもテキストか空が入るだけ。

## 背景

claude code に画像を渡したいときがある (UI のスクショ、エラー画面、デザイン参考、PDF の図など)。
ホストで動かしている時は ⌘V で paste できるが、docker コンテナ内で動かしている本プロジェクトの
構成では同じ操作ができず、毎回ホストで保存して `docker cp` などの遠回りが必要になる。

## 案 A: ファイル共有 + ドラッグ&ドロップ (シンプル)

ホストの画像保存場所を read-only で bind mount し、ターミナルにファイルをドラッグして
パスを入れる方式。

### 変更点

- `templates/docker-compose.yml.tmpl` の `claude` サービスに volume を追加:
  ```yaml
  volumes:
    - ${HOME}/Desktop:/host-paste:ro
    # もしくは専用ディレクトリ:
    # - ${HOME}/claude-paste:/host-paste:ro
  ```
- 任意で `CLAUDE_PASTE_DIR=/host-paste` を env に置いて claude / 人間が参照しやすくする
- `README.md` に「macOS の ⌘⇧4 でスクショ → Desktop → ターミナルへドラッグ → enter」の手順を追記

### Pros / Cons

- **+** 実装はマウント1行で済む。watcher プロセス不要。動作が決定的
- **+** スクショ以外 (ダウンロードした PDF / 画像) もそのまま使える
- **−** 「paste」ではなく「ドラッグ」なので体験は劣る
- **−** Desktop 全体をマウントするのは privacy 的に微妙。専用ディレクトリ運用推奨

## 案 B: クリップボードブリッジ (paste っぽい UX)

ホスト側にクリップボード watcher を常駐させ、画像が乗ったら共有ディレクトリへファイル化する。
コンテナ内では `@/clipboard/latest.png` のように固定パスで参照する。

### 構成

- ホスト: `brew install pngpaste` でクリップボード→PNG 変換 CLI を入れる
- ホスト常駐スクリプト (LaunchAgent 化 / `task paste-watch` 等):
  ```bash
  # 雛形 (擬似コード)
  mkdir -p ~/.cache/claude-paste
  while :; do
    if pngpaste ~/.cache/claude-paste/.staging.png 2>/dev/null; then
      # ハッシュ比較で前回と同じならスキップ
      mv ~/.cache/claude-paste/.staging.png ~/.cache/claude-paste/latest.png
    fi
    sleep 0.5
  done
  ```
- compose 側で共有:
  ```yaml
  volumes:
    - ${HOME}/.cache/claude-paste:/clipboard:ro
  ```
- claude では `@/clipboard/latest.png` を直接参照

### Pros / Cons

- **+** 「ホストで ⌘C → コンテナ内 claude で参照」で paste 感覚に近い
- **+** ホスト/コンテナで同じパスにすれば人間も `eza /clipboard` で確認できる
- **−** 常駐 watcher の管理コスト (LaunchAgent / `task` での起動・停止)
- **−** macOS 専用。Linux ホストなら `wl-paste` / `xclip` で再実装が必要
- **−** クリップボードを polling するので CPU は微小だが0ではない
- **−** 履歴 (直前数枚) が欲しくなったら追加実装

## 推奨方針

1. まず **案 A** を最小実装 (専用 `~/claude-paste/` を作って bind mount + README)。
   日常運用にどれくらい不便かを測る。
2. ドラッグ操作がうるさいと感じたら **案 B** に発展。watcher の置き場所 (Taskfile か
   LaunchAgent か) は実装時に決める。

## やらない選択肢

- `xclip` をコンテナに入れて X11 forwarding: コンテナを GUI 対応にする必要があり overkill。
  本プロジェクトの「軽量 dev コンテナ」方針に合わない。
- `docker cp` ベースのヘルパー: 毎回コマンドを打つことになり paste の代替になっていない。

## 関連

- 既存の Playwright Chromium サポート (`README.md` の「ブラウザ自動化」セクション) は
  コンテナ内でブラウザを動かす話で、本件 (ホストの画像をコンテナへ渡す) とは別軸。
