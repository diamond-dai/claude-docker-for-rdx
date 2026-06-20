// claude-docker 環境を「案件の隣」に生成する CLI。
//
// 使い方:
//
//	new-claude-env -a ACCOUNT [-n ENVNAME] <project-path>...
//
//	-a ACCOUNT  アカウント prefix(必須)。共有 volume とプロジェクト名に使う。
//	            prefix を変える = 別の Claude Code / gh アカウントで使う、という意味。
//	            環境変数 ACCT でも指定可(優先順位: -a > ACCT)。既定値なし。
//	-n ENVNAME  プロジェクト名を明示(単一ディレクトリ指定時のみ)。非ASCII名の案件用。
//
// 例:
//
//	new-claude-env -a gg ~/work/riku_dx_web_0
//	new-claude-env -a gg ~/work/riku_dx_web_*/        # サフィックス違いをまとめて
//	new-claude-env -a acme -n acme-a ~/work/案件A     # 非ASCIIは -n で明示
package main

import (
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

//go:embed all:templates
var templatesFS embed.FS

var sanitizeRe = regexp.MustCompile(`[^a-z0-9_-]`)

const manifestVersion = 1

type managedFile struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
}

type manifest struct {
	Version     int           `json:"version"`
	Account     string        `json:"account"`
	Project     string        `json:"project"`
	ComposeName string        `json:"compose_name"`
	Files       []managedFile `json:"files"`
}

// sanitize は compose のプロジェクト名 / volume 名で使える形(英小文字・数字・-・_)に整える。
func sanitize(s string) string {
	return sanitizeRe.ReplaceAllString(strings.ToLower(s), "-")
}

func mustReadTemplate(name string) string {
	b, err := templatesFS.ReadFile("templates/" + name)
	if err != nil {
		fatalf("read embedded template %s: %v", name, err)
	}
	return string(b)
}

func defaultClaudeDotfilesDir() string {
	if dir := os.Getenv("CLAUDE_DOTFILES_CLAUDE_DIR"); dir != "" {
		return expandHome(dir)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		fatalf("resolve home directory: %v", err)
	}
	return filepath.Join(home, "dotfiles", "config", "claude")
}

func expandHome(path string) string {
	if path == "~" {
		home, err := os.UserHomeDir()
		if err != nil {
			fatalf("resolve home directory: %v", err)
		}
		return home
	}
	if strings.HasPrefix(path, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			fatalf("resolve home directory: %v", err)
		}
		return filepath.Join(home, path[2:])
	}
	return path
}

func fatalf(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "error: "+format+"\n", a...)
	os.Exit(1)
}

func main() {
	var acct, envName string
	var update bool
	flag.StringVar(&acct, "a", "", "account prefix (required; or env ACCT)")
	flag.StringVar(&envName, "n", "", "project name override (single dir only)")
	flag.BoolVar(&update, "u", false, "update an existing generated environment")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: new-claude-env -a ACCOUNT [-n ENVNAME] [-u] <project-path>...")
		fmt.Fprintln(os.Stderr, "       (ACCOUNT は -a フラグまたは環境変数 ACCT で必須指定。フラグは引数より前)")
	}
	flag.Parse()

	// --- account prefix(必須): -a > 環境変数 ACCT ---
	if acct == "" {
		acct = os.Getenv("ACCT")
	}
	if acct == "" {
		fmt.Fprintln(os.Stderr, "error: account prefix is required (-a ACCOUNT or env ACCT)")
		flag.Usage()
		os.Exit(1)
	}
	acct = sanitize(acct)
	if acct == "" {
		fatalf("account prefix is empty after sanitizing")
	}

	args := flag.Args()
	if len(args) < 1 {
		flag.Usage()
		os.Exit(1)
	}

	// --- glob を自前展開(シェルが展開しなかった場合の保険)+ 重複排除 ---
	var paths []string
	seen := map[string]bool{}
	for _, a := range args {
		matches := []string{a}
		if strings.ContainsAny(a, "*?[") {
			if m, err := filepath.Glob(a); err == nil {
				matches = m // マッチ0件なら空になり、その引数はスキップされる
			}
		}
		for _, m := range matches {
			if !seen[m] {
				seen[m] = true
				paths = append(paths, m)
			}
		}
	}

	multi := len(paths) > 1
	if envName != "" && multi {
		fatalf("-n ENVNAME は単一ディレクトリ指定時のみ使えます(複数指定時は basename を使用)")
	}

	dockerfile := mustReadTemplate("Dockerfile")
	composeTmpl := mustReadTemplate("docker-compose.yml.tmpl")
	envExample := mustReadTemplate(".env.example")
	taskfile := mustReadTemplate("Taskfile.yml")
	setupClaudeDotfiles := mustReadTemplate("setup-claude-dotfiles.sh")
	claudeDockerInfo := mustReadTemplate("claude-docker-info.sh")
	scutil := mustReadTemplate("scutil")
	dockerWrapper := mustReadTemplate("docker")
	claudeDotfilesDir := defaultClaudeDotfilesDir()

	created, updated, unchanged, skipped := 0, 0, 0, 0
	for _, p := range paths {
		info, err := os.Stat(p)
		if err != nil || !info.IsDir() {
			fmt.Fprintf(os.Stderr, "skip (not a directory): %s\n", p)
			skipped++
			continue
		}
		abs, err := filepath.Abs(p)
		if err != nil {
			fmt.Fprintf(os.Stderr, "skip (abs failed): %s\n", p)
			skipped++
			continue
		}
		name := filepath.Base(abs)
		parent := filepath.Dir(abs)
		envDir := filepath.Join(parent, name+"-claude")

		// 複数指定(glob)時は、生成済みの *-claude を拾わないようガード
		if multi && strings.HasSuffix(name, "-claude") {
			fmt.Fprintf(os.Stderr, "skip (looks like a generated env): %s\n", name)
			skipped++
			continue
		}
		envExists := false
		if info, err := os.Stat(envDir); err == nil {
			if !info.IsDir() {
				fmt.Fprintf(os.Stderr, "skip (generated path is not a directory): %s\n", envDir)
				skipped++
				continue
			}
			envExists = true
			if !update {
				fmt.Fprintf(os.Stderr, "skip (already exists; use -u to update): %s-claude\n", name)
				skipped++
				continue
			}
		}

		base := name
		if envName != "" {
			base = envName
		}
		fullName := acct + "-" + sanitize(base) + "-claude"

		if err := os.MkdirAll(envDir, 0o755); err != nil {
			fatalf("mkdir %s: %v", envDir, err)
		}
		compose := strings.NewReplacer(
			"__PROJECT__", "../"+name,
			"__ENVNAME__", fullName,
			"__ACCT__", acct,
			"__ACCT_PROJECT__", acct+"-"+sanitize(base), // 通知/ターミナルタイトル用(例: gg-riku_dx_web_1)
			"__CLAUDE_DOTFILES__", claudeDotfilesDir,
		).Replace(composeTmpl)

		files := []struct {
			name    string
			content string
		}{
			{name: "Dockerfile", content: dockerfile},
			{name: "docker-compose.yml", content: compose},
			{name: ".env.example", content: envExample},
			{name: "Taskfile.yml", content: taskfile},
			{name: "setup-claude-dotfiles.sh", content: setupClaudeDotfiles},
			{name: "claude-docker-info.sh", content: claudeDockerInfo},
			{name: "scutil", content: scutil},
			{name: "docker", content: dockerWrapper},
		}

		changedFiles := make([]string, 0, len(files)+1)
		manifestFiles := make([]managedFile, 0, len(files))
		for _, file := range files {
			status := writeFileIfChanged(filepath.Join(envDir, file.name), file.content)
			if status != "unchanged" {
				changedFiles = append(changedFiles, file.name)
			}
			manifestFiles = append(manifestFiles, managedFile{
				Path:   file.name,
				SHA256: contentSHA256(file.content),
			})
		}

		manifestContent, err := json.MarshalIndent(manifest{
			Version:     manifestVersion,
			Account:     acct,
			Project:     name,
			ComposeName: fullName,
			Files:       manifestFiles,
		}, "", "  ")
		if err != nil {
			fatalf("marshal manifest: %v", err)
		}
		if writeFileIfChanged(filepath.Join(envDir, ".claude-docker.json"), string(manifestContent)+"\n") != "unchanged" {
			changedFiles = append(changedFiles, ".claude-docker.json")
		}

		switch {
		case !envExists:
			fmt.Printf("created: %s  (name: %s)\n", envDir, fullName)
			created++
		case len(changedFiles) > 0:
			fmt.Printf("updated: %s  (files: %s)\n", envDir, strings.Join(changedFiles, ", "))
			updated++
		default:
			fmt.Printf("unchanged: %s\n", envDir)
			unchanged++
		}
	}

	fmt.Printf("\ndone. created=%d updated=%d unchanged=%d skipped=%d  account=%s\n",
		created, updated, unchanged, skipped, acct)
	if created > 0 {
		fmt.Printf(`
next (この account で初回だけ):
  docker volume create %[1]s-claude-enterprise
  docker volume create %[1]s-claude-state
  docker volume create %[1]s-gh-config
  ssh-add <この account の git 秘密鍵>           # Linux はさらに HOST_SSH_AUTH_SOCK を export

起動(生成した各環境で):
  cd <生成した環境>
  task up
  task claude
  # ログインは1回でOK(同じ account の volume を共有):
  #   task claude
  #   task gh-login
`, acct)
	}
}

func contentSHA256(content string) string {
	sum := sha256.Sum256([]byte(content))
	return hex.EncodeToString(sum[:])
}

func writeFileIfChanged(path, content string) string {
	current, err := os.ReadFile(path)
	if err == nil && string(current) == content {
		return "unchanged"
	}
	status := "updated"
	if os.IsNotExist(err) {
		status = "created"
	} else if err != nil {
		fatalf("read %s: %v", path, err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		fatalf("write %s: %v", path, err)
	}
	return status
}
