# claude-docker(案件ごと・案件gitを汚さない)

案件ごとに claude-docker 環境を「案件の隣のディレクトリ」に生成するスクリプト一式。
案件リポジトリには一切ファイルを入れないので、git が汚れず compose も被らない。

## 仕組み

```
~/work/
├── myproject/              ← 案件リポジトリ(アプリのみ・触らない)
│   ├── docker-compose.yml  ← アプリ本体(web/api/db)※案件の正規ファイル
│   ├── web/
│   └── api/
└── myproject-claude/       ← ← scaffold が生成(claude-docker・git管理外)
    ├── docker-compose.yml  ← ../myproject を /workspace に指す
    ├── Dockerfile
    ├── .env.example
    ├── Taskfile.yml
    └── .claude-docker.json
```

- claude コンテナ … Claude Code 本体 / tmux / git(SSH agent 転送)
- dind コンテナ  … 隔離された Docker デーモン。案件アプリはこの中で起動
- `/workspace` = 隣の案件リポジトリだけ → 対象を間違えない

## 同梱物

- `main.go` / `go.mod` … 生成ツール。テンプレを埋め込む単一バイナリにできる
- `templates/` … 生成元(Dockerfile / docker-compose.yml.tmpl / .env.example / Taskfile.yml)
- `README.md`

### ツールの用意

テンプレートを埋め込むので、ビルド後はバイナリ1個で完結する。

```bash
go build -o new-claude-env .
./new-claude-env -a gg ~/work/myproject
```

## 認証(3つの目的は別経路)

| 目的 | 認証に使うもの | 仕組み |
|---|---|---|
| Claude = Enterprise | claude.ai の OAuth(`~/.claude`) | `gg-claude-enterprise` volume + `/login` |
| Claude の初回状態 | `~/.claude.json` | `gg-claude-state` volume に保存 |
| git = github-gg(会社) | SSH キー(gg の鍵) | agent 転送、`git@github.com:...` |
| gh コマンド | `gh auth login`(OAuth) | `gg-gh-config` volume に保存 |

git(SSH)と gh(API)は別経路。SSH キーだけでは gh は通らない(逆も同様)。

> **GitHub Enterprise の PAT について**
> Enterprise だと fine-grained PAT は org オーナーの承認が必要で、classic PAT は禁止のことも多い。
> そのため手動 PAT(`GH_TOKEN`)に頼らず、**`gh auth login` の OAuth(デバイスフロー)**を主経路にする。
> GitHub CLI 公式 OAuth アプリ経由なので PAT の個別承認を回避できる
> (組織が GitHub CLI の OAuth アプリを許可していること前提)。

## 前提(1回だけ)

```bash
# (1) 同じ account(既定 gg)のプロジェクトで共有する protected volume(external)
docker volume create gg-claude-enterprise
docker volume create gg-claude-state
docker volume create gg-gh-config

# (2) git: gg の鍵を agent に登録(秘密鍵はコンテナに入れない)
#     ※ コンテナを「gg だけ」にしたいので、gg の鍵だけ乗せるのが安全。
#
# macOS(Docker Desktop):
#   コンテナへ転送されるのは「既定の agent(launchd/keychain)」だけ。
#   `eval "$(ssh-agent -s)"` で別 agent を立てると Docker Desktop は転送しないので使わない。
ssh-add ~/ssh_keys/gg/gg-github/gg-git_id_ed25519   # --apple-use-keychain も可
ssh-add -l                                          # 0 件だと転送されない(必ず確認)
```

> 確認: `task up` 後に `task doctor` の `ssh-agent:` 行を見る。
> `identities: 0` ならホストの `ssh-add` が効いていない(別 agent に入れていないか確認)。
> `identities: 接続不可` ならソケット権限の問題で、`task up` が `/ssh-agent` を user 所有に直す。

> **account prefix について(= アカウントの切り替え・必須)**
> 共有 volume とプロジェクト名には account prefix が付く。`claude-docker` 自体は1つで、
> **prefix を変えるだけで別の Claude Code / gh アカウントとして使える**。
> **prefix は必須**(既定値なし)。`-a` フラグか環境変数 `ACCT` で必ず指定する。
>  - `<prefix>-claude-enterprise` … その account の Claude ログインを保持(`/login` 先)
>  - `<prefix>-claude-state` … その account の `~/.claude.json` を保持(machineID / firstStartTime 等)
>  - `<prefix>-gh-config` … その account の gh ログインを保持
>  - プロジェクト名 … `<prefix>-<案件名>-claude`
>    (dind-storage も `<prefix>-<案件名>-claude_dind-storage`)
>
> prefix の指定(優先順): `-a` フラグ > 環境変数 `ACCT`。どちらも無ければエラーで停止する。
> ```bash
> ./new-claude-env -a gg        ~/work/riku_dx_web_0   # 会社アカウント
> ./new-claude-env -a personal  ~/work/sandbox         # 個人アカウント(別ログイン)
> ./new-claude-env -a acme      ~/work/acme-project     # 別クライアント(別ログイン)
> ACCT=gg ./new-claude-env      ~/work/riku_dx_web_1   # 環境変数でも可
> ```
> 同じ prefix のプロジェクトは認証 volume を共有 → その account のログインは1回でよい。
> prefix が違えば volume も別 → それぞれ独立した Claude / gh アカウントになる。
> これらは `external: true` の protected volume なので、`docker compose down -v` でも削除されない。
>
> ※ git(SSH)は agent 転送なので prefix では切り替わらない。account を変えたら、
>    その account の git 鍵を `ssh-add` すること(下記)。

### git を確実に github-gg(会社)にする

コンテナの agent に **gg の鍵だけ**が乗っていれば、`git@github.com:...` がそのまま gg で通る
(同一ホストに鍵が1本なら迷わない)。dai の鍵も混ざる環境では、どちらが選ばれるか不定になるので
以下のどちらかで gg を固定する。

- **Linux**: gg 専用の agent を立てて、その socket だけ転送する(dai の鍵をコンテナに渡さない)
  ```bash
  export HOST_SSH_AUTH_SOCK="$(mktemp -u)"
  ssh-agent -a "$HOST_SSH_AUTH_SOCK" >/dev/null
  SSH_AUTH_SOCK="$HOST_SSH_AUTH_SOCK" ssh-add ~/ssh_keys/gg/gg-github/gg-git_id_ed25519
  ```
- **どの OS でも / エイリアスを使いたい**: `git@github-gg:...` の `github-gg` は
  イメージ側の `~/.ssh/config` で `github.com` へ解決済み(Dockerfile 参照)なので、
  リポジトリの remote がエイリアスのままでも push できる。鍵の選択は agent の中身次第なので、
  gg 以外の鍵も混ざるなら上の Linux 方式で gg 専用 agent を立てるのが確実。

### gh を会社アカウントにする(PAT 不要)

コンテナ内で一度だけ OAuth ログインする。デバイスフローなのでブラウザのコールバックは不要。

```bash
docker compose exec claude gh auth login
#  → GitHub.com か Enterprise Server を選択
#  → 表示されたワンタイムコードをメモ
#  → ホストのブラウザで https://github.com/login/device を開いてコード入力・認可
```

トークンは `gg-gh-config` volume に保存されるので、リビルドしても再ログイン不要。

- **Enterprise Server(自前ホスト)**の場合は `gh auth login --hostname ghe.会社ドメイン`。
  併せて ssh config の `HostName` も自社 GHES ホストに変える。
- 会社が SAML SSO の場合、ログイン時に SSO 認可が走る。
- どうしても PAT を使う場合(承認が取れる/CI 用途)だけ、`export GH_TOKEN=...` で起動すれば
  そちらが優先される(`gh auth login` 不要)。

## 使い方

```bash
# 案件の隣に環境を生成(-a でアカウントを必ず指定)
./new-claude-env -a gg ~/work/myproject
#   → ~/work/myproject-claude/ ができる

# サフィックス違いをワイルドカードでまとめて生成(末尾スラッシュでディレクトリのみ対象)
./new-claude-env -a gg ~/work/riku_dx_web_*/
#   → riku_dx_web_0-claude 〜 _3-claude をまとめて作成
#   再実行は冪等(既存 / 生成済み *-claude は自動スキップ)

# 起動 → Claude Code
cd ~/work/myproject-claude
task up
task claude               # /login(初回のみ)
```

生成される `Taskfile.yml` では以下の操作ができる。

| コマンド | 処理 |
|---|---|
| `task up` | Claude / DinD コンテナを起動 |
| `task rebuild` | ベースイメージとClaude Codeを最新版で再ビルド |
| `task dotfiles` | dotfiles の Claude Code 設定を再リンク |
| `task prepull` | 共通イメージを案件専用 DinD キャッシュへ事前pull |
| `task claude` | Claude Opus 4.7 1M で Claude Code を起動 |
| `task claude-opus-4-7` | Claude Opus 4.7 1M で Claude Code を起動 |
| `task shell` | Claude コンテナの bash を開く |
| `task dev` | Claude コンテナ内で `pnpm dev` を実行 |
| `task tmux` | 永続 tmux セッションへ接続 |
| `task gh-login` | GitHub CLI にログイン |
| `task logs` | Compose ログを追跡 |
| `task ps` | コンテナ状態を表示 |
| `task versions` | Claude Code / uv / pnpm / Biome / Node.js のバージョンを表示 |
| `task doctor` | claude-docker環境のハッシュ・認証状態を表示 |
| `task down` | コンテナを停止・削除 |

`task shell`、`task claude`、`task claude-opus-4-7`、`task dev` などの exec 系タスクは、
コンテナが未起動なら先に `task up` を実行する。
`task claude` と `task claude-opus-4-7` は起動前に `task doctor` を実行し、
ホスト側マニフェストとコンテナイメージ内マニフェストのハッシュを表示する。
`claude` コンテナ内の Docker CLI は wrapper 経由で dind を操作する。`DOCKER_HOST` は
Claude Code プロセス全体には渡さないため、Claude Code からは通常のコンテナ内 CLI として見える。
`task dev` は dind 内に起動した Postgres へ接続できるように、実行時だけ
`DATABASE_URL=postgresql://postgres:postgres@dind:5432/rikudxdb` を渡す。

Claude Code は推奨のネイティブインストーラーで導入する。起動時および実行中に更新を確認し、
バックグラウンドで取得した更新は次回起動時に反映される。コンテナイメージ自体も更新する場合は
`task rebuild` を実行する。
`uv`、`pnpm`、Biome はイメージビルド時点の最新版をインストールするため、更新する場合も `task rebuild` を使う。
`riku_dx_web` の `pnpm dev` を動かせるように、Python 3.13、PostgreSQL client、Tesseract 日本語OCR、
Noto CJK fonts、ビルドツールも入れる。ホストポートは公開しないため、複数環境を同時起動しても
ポート衝突しない。

ホストの `~/dotfiles/config/claude` はコンテナ内の `/dotfiles/claude` に read-only でマウントされる。
`settings.json` はそのままリンクせず、`remoteControlAtStartup` と `agentPushNotifEnabled` を除外した
コンテナ用設定として `~/.claude/settings.json` に生成する。`hooks`、`statusline-command.sh`、`skills`、
`CLAUDE.md`、`plugins/marketplaces/custom-lsp` はシンボリックリンクされる。`settings.local.json` はリンクせず、
Claude 認証 volume 側に置く。Claude Code の初回起動状態やアカウント情報を持つ `~/.claude.json` は
`~/.claude-state/.claude.json` へ移して symlink し、認証とは別の protected volume で永続化する。
既存の `~/.claude/.claude.json` は初回起動時に `~/.claude-state/.claude.json` へ移行される。通知フックとstatusline用に
`jq`、`python3`、`gofmt` 用の Go もコンテナへ入れる。別の場所を使う場合は生成時に
`CLAUDE_DOTFILES_CLAUDE_DIR=/path/to/claude-config` を指定する。

既存の生成先をテンプレートとの差分だけ更新する場合:

```bash
./new-claude-env -a gg -u ~/work/myproject

# go run で riku_dx_web_0 〜 riku_dx_web_9 をまとめて更新
go run . -a gg -u ../riku_dx_web_[0-9]/
```

管理対象と内容のハッシュは `.claude-docker.json` に記録される。`-u` を付けない場合、
既存の生成先は従来どおりスキップされる。生成先を Git 管理する場合も、実際に内容が
変わったファイルだけが書き換わるため、そのまま `git diff` で確認できる。

### gg環境に反映するには

このリポジトリでテンプレートを変更したあと、既存の `riku_dx_web_*` 用 claude 環境へ反映する:

```bash
go run . -a gg -u ../riku_dx_web_[0-9]/
```

Dockerfile が変わった場合は、各生成先でリビルドする:

```bash
cd ../riku_dx_web_0-claude
task rebuild

cd ../riku_dx_web_1-claude
task rebuild
```

非 ASCII 名の案件は、`-n` でプロジェクト名を明示(単一ディレクトリ時のみ):

```bash
./new-claude-env -a acme -n acme-a ~/work/案件A
```

## 案件ごとに分離される / 共有されるもの

| 対象 | 扱い |
|---|---|
| dind デーモン・dind-storage・コンテナ・network | 案件ごとに分離(name で namespace 化) |
| `/workspace`(ソース) | その案件リポジトリだけを bind |
| `gg-claude-enterprise` / `gg-claude-state` / `gg-gh-config`(認証・初回状態) | 同じ account で共有(external)→ `down -v` でも削除されない |

複数案件を同時に立ち上げても衝突しない。各案件が独立した privileged dockerd を持つため、
同時起動数が増えると RAM/CPU は台数分かかる点だけ注意。

## tmux でリモート操作

```bash
ssh user@host                                          # 手元PC → ホスト
cd ~/work/myproject-claude
docker compose exec claude tmux new -A -s myproject    # アタッチ(無ければ作成)
```

`Ctrl-b d` でデタッチしてもセッションは生存。ペイン分割は `Ctrl-b %` / `Ctrl-b "`。
外(インターネット)からは、ホストの SSH を直開けせず Tailscale/VPN か踏み台経由を推奨。

## 案件アプリ側(別途)

このリポジトリは「Claude を動かす箱」だけ。案件アプリの compose
(web/api/db)は案件側に置き、別途「ソース=bind / 書き込み=volume」のマスクを適用する
(node_modules・.next・.venv は volume、DB は named volume、`PYTHONDONTWRITEBYTECODE=1` で
__pycache__ を抑止)。これにより、ホストでも dind でも起動でき同時でも干渉しない。

## セキュリティメモ(官公庁案件向け)

- 案件 git は汚さない(claude-docker は案件の外に生成)。
- SSH はエージェント転送のため秘密鍵はコンテナに入らない。個人鍵より案件用 deploy key /
  fine-grained PAT を ssh-add する方が漏えい時の影響範囲を限定できる。
- `dind` は privileged が必要。案件ポリシー上の可否を要確認(不可なら rootless DinD 等を検討)。
- `StrictHostKeyChecking no` で検証を無効化しない(known_hosts を正しく入れる/Dockerfile 済み)。
- `USER user`(非root)は外さない(`--dangerously-skip-permissions` は root で拒否される)。
- claude.ai ログイン認証構成(Bedrock 不使用)。`CLAUDE_CODE_USE_BEDROCK` 等は不要。
