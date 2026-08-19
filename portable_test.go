package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestWrapExecutableFor(t *testing.T) {
	cases := []struct {
		argv []string
		win  bool
		want []string
	}{
		{[]string{`C:\p\shen.cmd`, "x"}, true, []string{"cmd", "/c", `C:\p\shen.cmd`, "x"}},
		{[]string{"builders/lisp/build.sh", "a"}, true, []string{"sh", "builders/lisp/build.sh", "a"}},
		{[]string{`C:\p\app.exe`}, true, []string{`C:\p\app.exe`}},
		{[]string{"/x/app"}, false, []string{"/x/app"}},
	}
	for _, c := range cases {
		if got := wrapExecutableFor(c.argv, c.win); !reflect.DeepEqual(got, c.want) {
			t.Errorf("wrapExecutableFor(%v, %v) = %v, want %v", c.argv, c.win, got, c.want)
		}
	}
}

func TestFindExecutableFor(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "shen.exe"), []byte("MZ"), 0o644)
	base := filepath.Join(dir, "shen")
	if got := findExecutableFor(base, true, []string{".exe"}); got != base+".exe" {
		t.Errorf("windows ext = %q", got)
	}
	if got := findExecutableFor(base, false, []string{".exe"}); got != "" {
		t.Errorf("posix must not invent .exe: %q", got)
	}
}

func TestReorderArgs(t *testing.T) {
	// flags after positionals get pulled forward; value-flag values stay attached
	got := reorderArgs([]string{"prog.shen", "out", "--target", "js", "--run"}, "target")
	want := []string{"--target", "js", "--run", "prog.shen", "out"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("reorderArgs = %v, want %v", got, want)
	}
}

func TestReorderArgsWebBoolFlag(t *testing.T) {
	// --web is a bool flag (not in valueFlags): it must be pulled forward WITHOUT
	// swallowing the following positional, so PROG/OUTDIR survive intact.
	got := reorderArgs([]string{"prog.shen", "out", "--target", "js", "--web"}, "host", "eval-style", "target")
	want := []string{"--target", "js", "--web", "prog.shen", "out"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("reorderArgs(--web) = %v, want %v", got, want)
	}
}

// --web on an eval-capable program has no valid resolution (--linked is
// mutually exclusive), so the preflight must fail early and say why.
func TestWebPreflight(t *testing.T) {
	write := func(dir, name, body string) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	// eval-free: preflight passes.
	ok := t.TempDir()
	write(ok, "yggdrasil.manifest.txt", "needs-eval=false\ncannot-reach=eval\n")
	write(ok, "b.kl", "(defun add2 (V1) (+ V1 2))\n")
	if err := webPreflight(ok); err != nil {
		t.Errorf("eval-free program must pass preflight, got: %v", err)
	}

	// eval-capable: preflight fails, names the culprit, and does NOT repeat
	// the stage-2 builder's impossible "--linked" advice as the remedy.
	bad := t.TempDir()
	write(bad, "yggdrasil.manifest.txt", "needs-eval=true\nreaches=eval\n")
	write(bad, "p.kl", "(tc +)\n\n(defun p (V1) (eval V1))\n")
	write(bad, "kernel.kl", "(defun shen.eval-without-macros (V1) (eval-kl V1))\n")
	err := webPreflight(bad)
	if err == nil {
		t.Fatal("needs-eval=true must fail the --web preflight")
	}
	for _, want := range []string{"needs-eval=true", "mutually exclusive", "eval", "tc"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("preflight message missing %q:\n%s", want, err)
		}
	}
	// kernel.kl is not user code: its eval-kl must not be blamed on the author.
	if strings.Contains(err.Error(), "eval-kl") {
		t.Errorf("preflight blamed kernel.kl:\n%s", err)
	}

	// No manifest at all: stay quiet and let the stage-2 builder report.
	if err := webPreflight(t.TempDir()); err != nil {
		t.Errorf("missing manifest must not fail preflight, got: %v", err)
	}
}

func TestLoadBuildersEmbedded(t *testing.T) {
	b, err := loadBuilders()
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"lisp", "lua", "go", "rust", "js", "truffle", "truffle-native"} {
		if _, ok := b[want]; !ok {
			t.Errorf("missing target %q", want)
		}
	}
}

func TestTruffleBuilderRecipes(t *testing.T) {
	b, err := loadBuilders()
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, format, output, run0 string
	}{
		{"truffle", "jvm", "{outdir}/app-truffle", "{outdir}/app-truffle/bin/shen-truffle"},
		{"truffle-native", "native", "{outdir}/app-truffle-native", "{outdir}/app-truffle-native"},
	} {
		bld, ok := b[tc.name]
		if !ok || len(bld.Build) != 2 {
			t.Fatalf("%s: expected Maven packaging and builder steps", tc.name)
		}
		argv := bld.Build[len(bld.Build)-1].Argv
		joined := strings.Join(argv, " ")
		if !strings.Contains(joined, "--format "+tc.format) || !strings.Contains(joined, tc.output) || !strings.Contains(joined, "--runtime {shen_truffle}/target/shen-truffle.jar") {
			t.Errorf("%s: recipe = %v", tc.name, argv)
		}
		if len(bld.Run) == 0 || bld.Run[0] != tc.run0 {
			t.Errorf("%s: run = %v, want prefix %q", tc.name, bld.Run, tc.run0)
		}
	}
}
