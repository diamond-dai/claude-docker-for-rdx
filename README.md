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
    └── .env.example
```

- claude コンテナ … Claude Code 本体 / tmux / git(SSH agent 転送)
- dind コンテナ  … 隔離された Docker デーモン。案件アプリはこの中で起動
- `/workspace` = 隣の案件リポジトリだけ → 対象を間違えない

## 同梱物

- `main.go` / `go.mod` … 生成ツール。テンプレを埋め込む単一バイナリにできる
- `templates/` … 生成元(Dockerfile / docker-compose.yml.tmpl / .env.example)
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
# (1) 同じ account(既定 gg)のプロジェクトで共有する認証 volume(external)
docker volume create gg-claude-enterprise
docker volume create gg-gh-config

# (2) git: gg の鍵を agent に登録(秘密鍵はコンテナに入れない)
#     ※ コンテナを「gg だけ」にしたいので、gg の鍵だけ乗せるのが安全。
eval "$(ssh-agent -s)"
ssh-add ~/ssh_keys/gg/gg-github/gg-git_id_ed25519
```

> **account prefix について(= アカウントの切り替え・必須)**
> 共有 volume とプロジェクト名には account prefix が付く。`claude-docker` 自体は1つで、
> **prefix を変えるだけで別の Claude Code / gh アカウントとして使える**。
> **prefix は必須**(既定値なし)。`-a` フラグか環境変数 `ACCT` で必ず指定する。
>  - `<prefix>-claude-enterprise` … その account の Claude ログインを保持(`/login` 先)
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
- **どの OS でも / エイリアスを使いたい**: `~/.ssh/config` と `.pub` をコンテナに read-only マウント
  (compose のコメント参照)し、`git@github-gg:...` を使う。`IdentitiesOnly yes` で gg に固定される。
  ※ macOS/Windows の Docker Desktop は任意 socket の転送ができないため、こちらが確実。

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

# 起動 → ログイン → tmux
cd ~/work/myproject-claude
docker compose up -d
docker compose exec claude claude               # /login(初回のみ)
docker compose exec claude tmux new -A -s myproject
```

複数まとめて起動する場合:

```bash
for d in ~/work/riku_dx_web_*-claude/; do (cd "$d" && docker compose up -d); done
# 認証は同じ account の volume を共有するので、ログインはどれか1つで1回でよい
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
| `gg-claude-enterprise` / `gg-gh-config`(認証) | 同じ account で共有(external)→ ログインは1回 |

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
- `USER node`(非root)は外さない(`--dangerously-skip-permissions` は root で拒否される)。
- claude.ai ログイン認証構成(Bedrock 不使用)。`CLAUDE_CODE_USE_BEDROCK` 等は不要。
