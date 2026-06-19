// Command ratatoskr is a friendly CLI around the Ratatoskr Shen tree-shaker.
//
// Ratatoskr itself is a Shen program (ratatoskr.shen) that runs on a host Shen
// port and shakes a Shen program into a minimal, portable KLambda slice;
// per-target builders then compile that slice into a standalone artifact. This
// Go binary makes both stages a one-liner and embeds the shaker source + the
// kernel KLambda slice, so it runs with no install (`go install` / a release
// binary), materialising the embedded tree to a cache dir on first use.
//
// Subcommands:
//
//	shake  PROG OUTDIR             stage 1: emit kernel.kl + <prog>.kl + manifest
//	build  PROG OUTDIR --target T  stage 1 + stage 2 builder for target T
//	run    PROG OUTDIR --target T  build, then execute the artifact (prints stdout)
//	targets                        list available stage-2 targets
package main

import (
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
)

// Embedded shaker source + kernel slice + per-language primitives + in-repo
// builders + the build recipe table, so the binary is self-contained.
//
//go:embed ratatoskr.shen builders.json
//go:embed KLambda
//go:embed Primitives
//go:embed builders
var embedded embed.FS

// ---- cross-platform helpers (kept in sync with bifrost's copies) ----

func isWindows() bool { return runtime.GOOS == "windows" }

func pathext() []string {
	raw := os.Getenv("PATHEXT")
	if raw == "" {
		raw = ".COM;.EXE;.BAT;.CMD"
	}
	var out []string
	for _, e := range strings.Split(raw, ";") {
		if strings.TrimSpace(e) != "" {
			out = append(out, strings.ToLower(e))
		}
	}
	return out
}

func findExecutablePath(path string) string { return findExecutableFor(path, isWindows(), pathext()) }

func findExecutableFor(path string, windows bool, exts []string) string {
	if _, err := os.Stat(path); err == nil {
		return path
	}
	if windows {
		for _, ext := range exts {
			if _, err := os.Stat(path + ext); err == nil {
				return path + ext
			}
		}
	}
	return ""
}

func wrapExecutable(argv []string) []string { return wrapExecutableFor(argv, isWindows()) }

func wrapExecutableFor(argv []string, windows bool) []string {
	if windows && len(argv) > 0 {
		low := strings.ToLower(argv[0])
		switch {
		case strings.HasSuffix(low, ".bat"), strings.HasSuffix(low, ".cmd"):
			return append([]string{"cmd", "/c"}, argv...)
		case strings.HasSuffix(low, ".sh"):
			return append([]string{"sh"}, argv...)
		}
	}
	return argv
}

// ---- materialised root ----

// ratRoot extracts the embedded tree to a versioned cache dir (once) and returns
// its path. ratatoskr.shen + KLambda must live on disk for the host to load them.
func ratRoot() (string, error) {
	shen, err := embedded.ReadFile("ratatoskr.shen")
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(shen)
	ver := hex.EncodeToString(sum[:])[:12]
	cache, err := os.UserCacheDir()
	if err != nil || cache == "" {
		cache = os.TempDir()
	}
	root := filepath.Join(cache, "ratatoskr-go", ver)
	sentinel := filepath.Join(root, ".ok")
	if _, err := os.Stat(sentinel); err == nil {
		return root, nil // already extracted
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return "", err
	}
	err = fs.WalkDir(embedded, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if p == "." {
			return nil
		}
		dst := filepath.Join(root, p)
		if d.IsDir() {
			return os.MkdirAll(dst, 0o755)
		}
		b, err := embedded.ReadFile(p)
		if err != nil {
			return err
		}
		mode := os.FileMode(0o644)
		if strings.HasSuffix(p, ".sh") {
			mode = 0o755
		}
		return os.WriteFile(dst, b, mode)
	})
	if err != nil {
		return "", err
	}
	os.WriteFile(sentinel, []byte(ver), 0o644)
	return root, nil
}

// ---- host (stage 1) ----

// defaultHost resolves the stage-1 host launcher argv, or nil.
func defaultHost() []string {
	for _, env := range []string{"RATATOSKR_HOST", "BIFROST_SHEN_CL"} {
		if v := os.Getenv(env); v != "" {
			parts := strings.Fields(v)
			if hit := findExecutablePath(parts[0]); hit != "" {
				return append([]string{hit}, parts[1:]...)
			}
		}
	}
	cwd, _ := os.Getwd()
	cand, _ := filepath.Abs(filepath.Join(cwd, "..", "shen-cl", "bin", "sbcl", "shen"))
	if hit := findExecutablePath(cand); hit != "" {
		return []string{hit}
	}
	return nil
}

// shake runs stage 1: shake prog into outdir. Returns outdir.
func shake(prog, outdir string, host []string, evalStyle string, quiet bool) (string, error) {
	if host == nil {
		host = defaultHost()
	}
	if host == nil {
		return "", fmt.Errorf("no Shen host launcher found. Set $RATATOSKR_HOST (or $BIFROST_SHEN_CL) to a Shen launcher, e.g.\n  RATATOSKR_HOST=/path/to/shen-cl/bin/sbcl/shen ratatoskr shake ...")
	}
	prog, _ = filepath.Abs(prog)
	outdir, _ = filepath.Abs(outdir)
	if _, err := os.Stat(prog); err != nil {
		return "", fmt.Errorf("program not found: %s", prog)
	}
	if err := os.MkdirAll(outdir, 0o755); err != nil {
		return "", err
	}
	root, err := ratRoot()
	if err != nil {
		return "", fmt.Errorf("materialising shaker: %w", err)
	}
	expr := fmt.Sprintf(`(ratatoskr.shake ["%s"] "%s")`, prog, outdir)

	var argv []string
	if evalStyle == "positional" {
		drv := filepath.Join(outdir, "_shake_driver.shen")
		os.WriteFile(drv, []byte("(load \"ratatoskr.shen\")\n"+expr+"\n"), 0o644)
		argv = append(append([]string{}, host...), drv)
	} else {
		argv = append(append([]string{}, host...), "eval", "-q", "-l", "ratatoskr.shen", "-e", expr)
	}

	out, _ := runAt(wrapExecutable(argv), root)
	kernel := filepath.Join(outdir, "kernel.kl")
	if fi, err := os.Stat(kernel); err != nil || fi.Size() == 0 {
		os.Stderr.WriteString(out)
		return "", fmt.Errorf("shake produced no kernel.kl (host=%s)\n  did the program load cleanly on the host?", strings.Join(host, " "))
	}
	if !quiet {
		os.Stderr.WriteString(out)
	}
	return outdir, nil
}

// runAt runs argv at cwd, returning combined output.
func runAt(argv []string, cwd string) (string, error) {
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Dir = cwd
	b, err := cmd.CombinedOutput()
	return string(b), err
}

// ---- stage 2 builders ----

type step struct {
	Argv []string          `json:"argv"`
	Cwd  string            `json:"cwd"`
	Env  map[string]string `json:"env"`
}

type builder struct {
	RunImpl string   `json:"run_impl"`
	DirEnv  string   `json:"dir_env"`
	Needs   []string `json:"needs"`
	Build   []step   `json:"build"`
	Run     []string `json:"run"`
}

func loadBuilders() (map[string]builder, error) {
	b, err := embedded.ReadFile("builders.json")
	if err != nil {
		return nil, err
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(b, &raw); err != nil {
		return nil, err
	}
	out := map[string]builder{}
	for k, v := range raw {
		if strings.HasPrefix(k, "_") {
			continue
		}
		var bd builder
		if err := json.Unmarshal(v, &bd); err != nil {
			return nil, fmt.Errorf("builder %s: %w", k, err)
		}
		out[k] = bd
	}
	return out, nil
}

func siblingDir(target string, b builder) string {
	if b.DirEnv != "" {
		if v := os.Getenv(b.DirEnv); v != "" {
			abs, _ := filepath.Abs(v)
			return abs
		}
	}
	name := map[string]string{
		"lua": "shen-lua", "go": "shen-go", "rust": "shen-rust",
		"js": "ShenScript", "julia": "shen-julia",
	}[target]
	cwd, _ := os.Getwd()
	abs, _ := filepath.Abs(filepath.Join(cwd, "..", name))
	return abs
}

func subst(s string, subs map[string]string) string {
	for k, v := range subs {
		s = strings.ReplaceAll(s, k, v)
	}
	return s
}

// build runs a target's stage-2 steps. Returns the run argv, or nil if a needed
// tool is missing.
func build(target, outdir string) ([]string, error) {
	builders, err := loadBuilders()
	if err != nil {
		return nil, err
	}
	b, ok := builders[target]
	if !ok {
		var names []string
		for k := range builders {
			names = append(names, k)
		}
		sort.Strings(names)
		return nil, fmt.Errorf("unknown target %q (have: %s)", target, strings.Join(names, ", "))
	}
	for _, tool := range b.Needs {
		if _, err := exec.LookPath(tool); err != nil {
			return nil, nil // tool missing -> caller treats as SKIP
		}
	}
	outdir, _ = filepath.Abs(outdir)
	root, err := ratRoot()
	if err != nil {
		return nil, err
	}
	tmp, _ := os.MkdirTemp("", "ratatoskr_build_")
	subs := map[string]string{
		"{ratroot}": root, "{outdir}": outdir, "{tmp}": tmp,
		"{shen_lua}": siblingDir("lua", b), "{shen_go}": siblingDir("go", b),
		"{shen_rust}": siblingDir("rust", b), "{shenscript}": siblingDir("js", b),
		"{shen_julia}": siblingDir("julia", b),
	}
	for _, st := range b.Build {
		argv := make([]string, len(st.Argv))
		for i, a := range st.Argv {
			argv[i] = subst(a, subs)
		}
		cwd := ""
		if st.Cwd != "" {
			cwd = subst(st.Cwd, subs)
		}
		cmd := exec.Command(wrapExecutable(argv)[0], wrapExecutable(argv)[1:]...)
		cmd.Dir = cwd
		cmd.Env = os.Environ()
		for k, v := range st.Env {
			cmd.Env = append(cmd.Env, k+"="+subst(v, subs))
		}
		cmd.Stdout, cmd.Stderr = os.Stderr, os.Stderr
		if err := cmd.Run(); err != nil {
			return nil, fmt.Errorf("build step failed for target %s: %s", target, strings.Join(argv, " "))
		}
	}
	runArgv := make([]string, len(b.Run))
	for i, a := range b.Run {
		runArgv[i] = subst(a, subs)
	}
	// Native-exe run path (e.g. {outdir}/app-go-bin) is app-go-bin.exe on Windows.
	if len(runArgv) > 0 && strings.ContainsAny(runArgv[0], `/\`) {
		if hit := findExecutablePath(runArgv[0]); hit != "" {
			runArgv[0] = hit
		}
	}
	return runArgv, nil
}

// ---- CLI ----

func main() { os.Exit(run(os.Args[1:])) }

func run(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: ratatoskr <shake|build|run|targets> ...")
		return 2
	}
	cmd, rest := args[0], args[1:]
	switch cmd {
	case "targets":
		builders, err := loadBuilders()
		if err != nil {
			fmt.Fprintln(os.Stderr, "ratatoskr:", err)
			return 1
		}
		var names []string
		for k := range builders {
			names = append(names, k)
		}
		sort.Strings(names)
		for _, t := range names {
			b := builders[t]
			fmt.Printf("%-6s runs on %-10s needs %s\n", t, b.RunImpl, strings.Join(b.Needs, ", "))
		}
		return 0
	case "shake", "build", "run":
		return cmdStage(cmd, rest)
	default:
		fmt.Fprintf(os.Stderr, "ratatoskr: unknown subcommand %q\n", cmd)
		return 2
	}
}

func cmdStage(cmd string, rest []string) int {
	fs := flag.NewFlagSet("ratatoskr "+cmd, flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	hostFlag := fs.String("host", "", `stage-1 host launcher (e.g. "node /p/shen.js"); default: shen-cl`)
	evalStyle := fs.String("eval-style", "sub", "how the host evaluates the shake expr (sub | positional)")
	target := fs.String("target", "", "stage-2 target (lisp/lua/go/rust/js/julia)")
	// Allow flags after the PROG/OUTDIR positionals (Go's flag stops at the
	// first non-flag token otherwise).
	if err := fs.Parse(reorderArgs(rest, "host", "eval-style", "target")); err != nil {
		return 2
	}
	if fs.NArg() < 2 {
		fmt.Fprintf(os.Stderr, "usage: ratatoskr %s PROG OUTDIR%s\n", cmd, map[string]string{"shake": ""}[cmd]+ifTarget(cmd))
		return 2
	}
	prog, outdir := fs.Arg(0), fs.Arg(1)
	var host []string
	if *hostFlag != "" {
		host = strings.Fields(*hostFlag)
		if hit := findExecutablePath(host[0]); hit != "" {
			host[0] = hit
		}
	}

	if cmd == "shake" {
		out, err := shake(prog, outdir, host, *evalStyle, false)
		if err != nil {
			fmt.Fprintln(os.Stderr, "ratatoskr:", err)
			return 1
		}
		fmt.Println("shaken ->", out)
		entries, _ := os.ReadDir(out)
		for _, e := range entries {
			fmt.Println("  " + e.Name())
		}
		return 0
	}

	// build / run
	if *target == "" {
		fmt.Fprintf(os.Stderr, "ratatoskr %s: --target is required\n", cmd)
		return 2
	}
	if _, err := shake(prog, outdir, host, *evalStyle, true); err != nil {
		fmt.Fprintln(os.Stderr, "ratatoskr:", err)
		return 1
	}
	runArgv, err := build(*target, outdir)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ratatoskr:", err)
		return 1
	}
	if runArgv == nil {
		fmt.Fprintf(os.Stderr, "ratatoskr: target %q skipped (a required tool is not on PATH)\n", *target)
		return 3
	}
	if cmd == "build" {
		fmt.Printf("built %s artifact; run with:\n  %s\n", *target, strings.Join(runArgv, " "))
		return 0
	}
	// run
	argv := wrapExecutable(runArgv)
	c := exec.Command(argv[0], argv[1:]...)
	c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := c.Run(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return ee.ExitCode()
		}
		fmt.Fprintln(os.Stderr, "ratatoskr:", err)
		return 1
	}
	return 0
}

func ifTarget(cmd string) string {
	if cmd == "shake" {
		return ""
	}
	return " --target T"
}

// reorderArgs moves flags (and the values of named value-flags) ahead of
// positionals so flags may appear after PROG/OUTDIR. Mirrors bifrost's helper.
func reorderArgs(args []string, valueFlags ...string) []string {
	vf := map[string]bool{}
	for _, f := range valueFlags {
		vf[f] = true
	}
	var flags, pos []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			pos = append(pos, args[i+1:]...)
			break
		}
		if strings.HasPrefix(a, "-") && a != "-" {
			flags = append(flags, a)
			name := strings.TrimLeft(a, "-")
			if eq := strings.IndexByte(name, '='); eq >= 0 {
				name = name[:eq]
			} else if vf[name] && i+1 < len(args) {
				i++
				flags = append(flags, args[i])
			}
		} else {
			pos = append(pos, a)
		}
	}
	return append(flags, pos...)
}
