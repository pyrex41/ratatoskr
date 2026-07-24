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
//	                               (--web with --target js: emit a browser module)
//	run    PROG OUTDIR --target T  build, then execute the artifact (prints stdout)
//	parity PROG OUTDIR             behavioural parity gate: run the shaken slice on
//	                               every target and diff outputs against a reference
//	targets                        list available stage-2 targets
package main

import (
	"bytes"
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
	"time"
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

// embeddedHash returns a short content hash over the entire embedded tree, so
// the materialised cache is keyed by exactly what would be extracted.
func embeddedHash() (string, error) {
	h := sha256.New()
	err := fs.WalkDir(embedded, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		b, err := embedded.ReadFile(p)
		if err != nil {
			return err
		}
		h.Write([]byte(p))
		h.Write(b)
		return nil
	})
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil))[:12], nil
}

// ---- materialised root ----

// ratRoot extracts the embedded tree to a versioned cache dir (once) and returns
// its path. ratatoskr.shen + KLambda + builders must live on disk for the host
// and the stage-2 builders. The cache key hashes the WHOLE embedded tree, so any
// change to the shaker, kernel, or a builder invalidates a stale cache.
func ratRoot() (string, error) {
	ver, err := embeddedHash()
	if err != nil {
		return "", err
	}
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

// defaultHost resolves the stage-1 host launcher argv, or nil. The sibling
// ../shen-cl/bin/sbcl/shen is used as-is: whatever binary is built there is
// the host. After the S41.2-refresh migration the reference host is a
// shen-cl built from its refreshed master; an older community-41.2 binary
// at that path still works (both produce byte-identical stage-1 output) —
// rebuild shen-cl master to refresh the host. Override with $RATATOSKR_HOST.
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
		"js": "ShenScript", "julia": "shen-julia", "scheme": "shen-scheme",
		"swift": "shen-swift", "lisp": "shen-cl", "hvm": "inets/shen-inets",
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
// tool is missing. When web is true, "--web" is appended to the ShenScript
// stage-2 builder step so it emits a browser-safe ES module (see the js target).
func build(target, outdir string, web bool) ([]string, error) {
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
		"{shen_julia}": siblingDir("julia", b), "{shen_scheme}": siblingDir("scheme", b),
		"{shen_swift}": siblingDir("swift", b), "{shen_cl}": siblingDir("lisp", b),
		"{shen_inets}": siblingDir("hvm", b),
	}
	for _, st := range b.Build {
		argv := make([]string, len(st.Argv))
		for i, a := range st.Argv {
			argv[i] = subst(a, subs)
		}
		// --web is a pass-through to ShenScript's stage-2 builder: emit a
		// browser-safe ES module instead of the default Node artifact.
		if web {
			for _, a := range argv {
				if strings.Contains(a, "ratatoskr-build.js") {
					argv = append(argv, "--web")
					break
				}
			}
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
		fmt.Fprintln(os.Stderr, "usage: ratatoskr <shake|build|run|parity|targets> ...")
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
	case "parity":
		return cmdParity(rest)
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
	web := fs.Bool("web", false, "with --target js: emit a browser-safe ES module (passes --web to ShenScript's builder)")
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
	if *web && *target != "js" {
		fmt.Fprintf(os.Stderr, "ratatoskr %s: --web only applies to --target js\n", cmd)
		return 2
	}
	if _, err := shake(prog, outdir, host, *evalStyle, true); err != nil {
		fmt.Fprintln(os.Stderr, "ratatoskr:", err)
		return 1
	}
	runArgv, err := build(*target, outdir, *web)
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

// ---- parity gate ----
//
// Byte-identical kernel.kl across hosts is necessary but not sufficient: the
// SAME KL can still execute differently per target (integer width, symbol
// interning, hash iteration order, memoisation growth). The parity gate runs a
// shaken slice through each stage-2 target and checks the rendered output
// against a reference (and against itself), catching divergence that the
// byte-identity check cannot. See docs/parity.md and GitHub issue #8.

// passSep is the convention separator: a parity fixture prints two identical
// passes (the same computation run twice in one process) separated by a line
// that is exactly "===". splitPasses lets the gate diff the two passes, which
// catches in-process boot-order / state-dependent nondeterminism.
const passSep = "==="

// canon normalises line endings and strips trailing blank lines so artifacts
// that differ only in CRLF or a trailing newline compare equal.
func canon(s string) string {
	return strings.TrimRight(strings.ReplaceAll(s, "\r\n", "\n"), "\n")
}

// splitPasses splits output on the first line equal to passSep, returning the
// two canonicalised halves. ok is false when the marker is absent (the
// two-pass check is then reported as N/A, not a failure).
func splitPasses(out string) (a, b string, ok bool) {
	lines := strings.Split(strings.ReplaceAll(out, "\r\n", "\n"), "\n")
	for i, ln := range lines {
		if strings.TrimSpace(ln) == passSep {
			return canon(strings.Join(lines[:i], "\n")),
				canon(strings.Join(lines[i+1:], "\n")), true
		}
	}
	return "", "", false
}

// firstDiff returns the 1-based number of the first differing line between x
// and y (already canonicalised by the caller) and the two lines' contents
// ("" past the end). line is 0 when x == y.
func firstDiff(x, y string) (line int, xs, ys string) {
	xl, yl := strings.Split(x, "\n"), strings.Split(y, "\n")
	n := len(xl)
	if len(yl) > n {
		n = len(yl)
	}
	at := func(s []string, i int) string {
		if i < len(s) {
			return s[i]
		}
		return ""
	}
	for i := 0; i < n; i++ {
		if at(xl, i) != at(yl, i) {
			return i + 1, at(xl, i), at(yl, i)
		}
	}
	return 0, "", ""
}

// runCapture runs an artifact and returns its stdout (stderr passes through, so
// runtime errors are visible but never part of the comparison).
func runCapture(argv []string) (string, int64, error) {
	a := wrapExecutable(argv)
	cmd := exec.Command(a[0], a[1:]...)
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, os.Stderr
	start := time.Now()
	err := cmd.Run()
	return out.String(), time.Since(start).Milliseconds(), err
}

type parityResult struct {
	target string
	status string // ok | skip | builderr | runerr
	outA   string
	outB   string
	runMs  int64
	err    error
}

func cmdParity(rest []string) int {
	fs := flag.NewFlagSet("ratatoskr parity", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	hostFlag := fs.String("host", "", `stage-1 host launcher (e.g. "node /p/shen.js"); default: shen-cl`)
	evalStyle := fs.String("eval-style", "sub", "how the host evaluates the shake expr (sub | positional)")
	targetFlag := fs.String("target", "", "comma-separated targets to check (default: all whose tools are on PATH)")
	reference := fs.String("reference", "lisp", "reference target whose output is the truth source")
	expect := fs.String("expect", "", "golden stdout file; when given it is the authoritative truth")
	timeFlag := fs.Bool("time", false, "report per-target wall-clock (advisory; never fails the gate)")
	if err := fs.Parse(reorderArgs(rest, "host", "eval-style", "target", "reference", "expect")); err != nil {
		return 2
	}
	if fs.NArg() < 2 {
		fmt.Fprintln(os.Stderr, "usage: ratatoskr parity PROG OUTDIR [--target a,b] [--reference R] [--expect FILE]")
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

	builders, err := loadBuilders()
	if err != nil {
		fmt.Fprintln(os.Stderr, "ratatoskr:", err)
		return 1
	}

	// Selected targets: explicit list, or every known target.
	var targets []string
	if *targetFlag != "" {
		for _, t := range strings.Split(*targetFlag, ",") {
			t = strings.TrimSpace(t)
			if t == "" {
				continue
			}
			if _, ok := builders[t]; !ok {
				fmt.Fprintf(os.Stderr, "ratatoskr: unknown target %q\n", t)
				return 2
			}
			targets = append(targets, t)
		}
	} else {
		for t := range builders {
			targets = append(targets, t)
		}
	}
	sort.Strings(targets)
	// Without a golden, the reference target must be built to supply the truth.
	if *expect == "" && !contains(targets, *reference) {
		if _, ok := builders[*reference]; !ok {
			fmt.Fprintf(os.Stderr, "ratatoskr: unknown reference target %q\n", *reference)
			return 2
		}
		targets = append([]string{*reference}, targets...)
	}

	// Stage 1, once.
	if _, err := shake(prog, outdir, host, *evalStyle, true); err != nil {
		fmt.Fprintln(os.Stderr, "ratatoskr:", err)
		return 1
	}
	outdir, _ = filepath.Abs(outdir)

	// Build + run each target twice (two boots), in deterministic order.
	results := map[string]*parityResult{}
	for _, t := range targets {
		r := &parityResult{target: t}
		results[t] = r
		runArgv, berr := build(t, outdir, false)
		if berr != nil {
			r.status, r.err = "builderr", berr
			continue
		}
		if runArgv == nil {
			r.status = "skip"
			continue
		}
		outA, ms, ea := runCapture(runArgv)
		outB, _, eb := runCapture(runArgv)
		r.outA, r.outB, r.runMs = outA, outB, ms
		if ea != nil || eb != nil {
			r.status = "runerr"
			if ea != nil {
				r.err = ea
			} else {
				r.err = eb
			}
			continue
		}
		r.status = "ok"
	}

	// Establish the truth output.
	var truth, truthSrc string
	if *expect != "" {
		b, err := os.ReadFile(*expect)
		if err != nil {
			fmt.Fprintln(os.Stderr, "ratatoskr: cannot read --expect file:", err)
			return 1
		}
		truth, truthSrc = canon(string(b)), "expect:"+filepath.Base(*expect)
	} else {
		ref := results[*reference]
		if ref == nil || ref.status != "ok" {
			fmt.Fprintf(os.Stderr, "ratatoskr: cannot establish a reference: target %q is %s "+
				"(install its toolchain or pass --expect FILE)\n", *reference,
				statusOr(ref, "unavailable"))
			return 1
		}
		truth, truthSrc = canon(ref.outA), "reference:"+*reference
	}

	// Report.
	fmt.Printf("parity gate: %s  (truth = %s)\n", filepath.Base(prog), truthSrc)
	fmt.Printf("%-8s %-6s %-9s %-9s %-8s\n", "target", "build", "vs-truth", "two-boot", "two-pass")
	fail := false
	checked := 0
	for _, t := range targets {
		r := results[t]
		switch r.status {
		case "skip":
			fmt.Printf("%-8s %-6s %s\n", t, "SKIP", "(toolchain not on PATH)")
			continue
		case "builderr":
			fmt.Printf("%-8s %-6s build failed: %v\n", t, "FAIL", r.err)
			fail = true
			continue
		case "runerr":
			fmt.Printf("%-8s %-6s run failed: %v\n", t, "FAIL", r.err)
			fail = true
			continue
		}
		checked++
		a := canon(r.outA)
		vsTruth := a == truth
		twoBoot := a == canon(r.outB)
		p1, p2, hasPasses := splitPasses(r.outA)
		twoPass := !hasPasses || p1 == p2
		tp := "N/A"
		if hasPasses {
			if twoPass {
				tp = "ok"
			} else {
				tp = "DIFFER"
			}
		}
		mark := func(b bool) string {
			if b {
				return "ok"
			}
			return "DIFFER"
		}
		extra := ""
		if *timeFlag {
			extra = fmt.Sprintf("  %dms", r.runMs)
		}
		fmt.Printf("%-8s %-6s %-9s %-9s %-8s%s\n", t, "ok", mark(vsTruth), mark(twoBoot), tp, extra)
		if !vsTruth {
			ln, xs, ys := firstDiff(a, truth)
			fmt.Printf("    vs-truth first diff @ line %d:\n      got:  %q\n      want: %q\n", ln, xs, ys)
		}
		if !twoBoot {
			ln, xs, ys := firstDiff(a, canon(r.outB))
			fmt.Printf("    two-boot first diff @ line %d:\n      bootA: %q\n      bootB: %q\n", ln, xs, ys)
		}
		if hasPasses && !twoPass {
			ln, xs, ys := firstDiff(p1, p2)
			fmt.Printf("    two-pass first diff @ line %d:\n      pass1: %q\n      pass2: %q\n", ln, xs, ys)
		}
		if !(vsTruth && twoBoot && twoPass) {
			fail = true
		}
	}
	if fail {
		fmt.Println("parity: FAIL")
		return 1
	}
	if checked == 0 {
		fmt.Println("parity: no targets checked (toolchains missing)")
		return 3
	}
	fmt.Printf("parity: PASS (%d target(s) checked)\n", checked)
	return 0
}

func contains(xs []string, x string) bool {
	for _, e := range xs {
		if e == x {
			return true
		}
	}
	return false
}

func statusOr(r *parityResult, dflt string) string {
	if r == nil {
		return dflt
	}
	return r.status
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
