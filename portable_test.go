package main

import (
	"os"
	"path/filepath"
	"reflect"
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

func TestLoadBuildersEmbedded(t *testing.T) {
	b, err := loadBuilders()
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"lisp", "lua", "go", "rust", "js"} {
		if _, ok := b[want]; !ok {
			t.Errorf("missing target %q", want)
		}
	}
}
