#!/usr/bin/env python3
"""
atlas_derive.py -- what each build ACTUALLY contains, read from the simulator.

The Silicon Atlas (docs/site) says, for every block, which builds it is in.
That claim used to rest on a regular expression over source files. A file
in a directory proves nothing, and an instantiation inside a generate block
that is switched off proves nothing either. So this tool compiles each build
the way its own make target compiles it, and reads the instance tree the
compiler elaborated:

  * simulation builds: `make -n -B <target>` prints the target's commands;
    only its sv2v and iverilog steps are replayed (no simulation runs), and
    the elaborated scope tree is read from the .vvp file Icarus writes
    (".scope module, "<instance>" "<module>" ..., <parent>").
  * FPGA plans: the plan's own source list, sv2v, then iverilog -s <core>.
  * the Tiny Tapeout tile: the SUBMITTED file, tt/tile/src/project.v.

Writes docs/atlas/derived.json: per build, every instance path and module,
and the sha256 of every source file that went in; per source file, its last
commit, so the site can link a permalink that does not move when unrelated
files change. `make site-check` re-hashes those files (no tools needed) and
fails when the RTL has moved on since the last `make atlas`.

    python3 tools/atlas_derive.py            write docs/atlas/derived.json
"""
import hashlib, json, pathlib, re, shlex, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "docs/atlas/derived.json"
SPEC = ROOT / "docs/atlas/atlas.yaml"

SCOPE = re.compile(r'^(S_0x[0-9a-f]+) \.scope (\w+), "([^"]+)" "([^"]+)"[^;]*?(?:, (S_0x[0-9a-f]+))?;')


def sh(cmd, cwd=ROOT, check=True):
    r = subprocess.run(cmd, cwd=cwd, shell=isinstance(cmd, str), capture_output=True, text=True)
    if check and r.returncode:
        raise SystemExit(f"atlas_derive: command failed ({r.returncode}): {cmd}\n{r.stdout[-2000:]}{r.stderr[-2000:]}")
    return r.stdout


def make_steps(target, tmp):
    """The target's sv2v / iverilog steps, as make would run them."""
    out = sh(["make", "-n", "-B", target, f"SIMTMP={tmp}"])
    joined = out.replace("\\\n", " ").splitlines()
    steps = []
    for line in joined:
        cwd = "."
        for part in line.split("&&"):
            part = part.strip()
            m = re.match(r"^cd (\S+)$", part)
            if m:
                cwd = str(pathlib.Path(cwd) / m.group(1)); continue
            word = part.split(" ", 1)[0]
            if word in ("sv2v", "iverilog") and "--define=FORMAL" not in part and " -E " not in part:
                # drop any trailing pipeline (warning filters) after iverilog
                part = re.split(r"\s2>&1\s*\|", part)[0]
                steps.append((cwd, part))
    return steps


def files_of(steps):
    """Every HDL source a build's commands name, repository-relative."""
    files = []
    for cwd, cmd in steps:
        for tok in shlex.split(cmd.split(">")[0]):
            if re.search(r"\.(s?v|vh|svh)$", tok) and not tok.startswith("/"):
                for p in sorted((ROOT / cwd).glob(tok)) if any(c in tok for c in "*?[") else [ROOT / cwd / tok]:
                    rel = p.resolve().relative_to(ROOT).as_posix()
                    if rel not in files and p.exists():
                        files.append(rel)
    return files


def scope_tree(vvp, dut):
    """Instances under the module `dut` (or the whole tree if dut is None)."""
    nodes, kids = {}, {}
    for line in pathlib.Path(vvp).read_text(errors="replace").splitlines():
        m = SCOPE.match(line)
        if m:
            sid, kind, name, mod, parent = m.groups()
            nodes[sid] = (kind, name, mod, parent)
            kids.setdefault(parent, []).append(sid)
    roots = [s for s, (k, n, mod, p) in nodes.items() if k == "module" and (mod == dut if dut else p is None)]
    if not roots:
        raise SystemExit(f"atlas_derive: {vvp}: no instance of '{dut}' was elaborated")
    out = []

    def walk(sid, path):
        kind, name, mod, _ = nodes[sid]
        if kind == "module":
            out.append({"path": path, "module": mod})
        for c in sorted(kids.get(sid, []), key=lambda s: nodes[s][1]):
            ck, cn, cm, _ = nodes[c]
            if ck in ("module", "generate", "begin"):
                walk(c, f"{path}.{cn}" if ck == "module" else f"{path}.{cn}")
    walk(roots[0], nodes[roots[0]][2])
    # generate/begin scopes contribute to paths only
    return out


def compile_build(b, tmp):
    if "make" in b:
        steps = make_steps(b["make"], tmp)
        if not steps:
            raise SystemExit(f"atlas_derive: make {b['make']} has no sv2v/iverilog step")
        for cwd, cmd in steps:
            sh(cmd, cwd=ROOT / cwd)
        vvp = next(re.search(r"-o (\S+)", c).group(1) for _, c in reversed(steps) if c.startswith("iverilog"))
        return files_of(steps), vvp, f"make {b['make']} (compile steps only)"
    files = b["files"]
    v = f"{tmp}/{b['id']}.v"
    vvp = f"{tmp}/{b['id']}.vvp"
    sv = [f for f in files if f.endswith(".sv")]
    plain = [f for f in files if not f.endswith(".sv")]
    srcs = plain
    if sv:
        sh(f"sv2v {' '.join(sv)} > {v}")
        srcs = plain + [v]
    sh(f"iverilog -g2012 -s {b['top']} -o {vvp} {' '.join(srcs)}")
    return files, vvp, f"sv2v + iverilog -s {b['top']} over the listed sources"


def plan_builds():
    import yaml
    out = []
    for p in sorted((ROOT / "plans").glob("*.yaml")):
        plan = yaml.safe_load(p.read_text())
        # the same list tools/hydra_bind.py hands the FPGA tools (its
        # generate()): the plan's sources plus the reset synchroniser. The
        # generated board top around the core holds only clocking and pins.
        files = plan["sources"] + ["common/rtl/hydra_rst_sync.sv"]
        out.append({"id": f"fpga-{p.stem}", "name": f"FPGA image {p.stem}", "kind": "fpga",
                    "target": "fpga", "plan": p.relative_to(ROOT).as_posix(),
                    "board": plan.get("board"), "top": plan["core"], "dut": plan["core"],
                    "clock_hz": plan.get("sys_hz"), "files": files})
    return out


def sha(p):
    return hashlib.sha256((ROOT / p).read_bytes()).hexdigest()


def repo_of(path):
    """(repository, path inside it, git directory) for a source file."""
    for sub, repo in (("tt/tile/", "Normansrule/tinytapeout-hydra"),
                      ("ext/pixelstorm-gpu/", "Normansrule/pixelstorm-gpu"),
                      ("ext/sixfold-cpu/", "Normansrule/sixfold-cpu")):
        if path.startswith(sub):
            return repo, path[len(sub):], ROOT / sub
    return "Normansrule/hydra-skywater130", path, ROOT


def last_commit(path):
    repo, inner, gd = repo_of(path)
    c = sh(["git", "log", "-1", "--format=%H", "--", inner], cwd=gd).strip()
    dirty = sh(["git", "status", "--porcelain", "--", inner], cwd=gd).strip()
    return repo, inner, c, bool(dirty)


def tool_versions():
    v = {}
    for name, cmd in (("iverilog", "iverilog -V 2>&1 | head -1"), ("sv2v", "sv2v --numeric-version"),
                      ("python", "python3 --version")):
        v[name] = sh(cmd, check=False).strip()
    return v


def main():
    import yaml
    spec = yaml.safe_load(SPEC.read_text())
    builds = spec["builds"] + plan_builds()
    derived = {"_comment": "Generated by tools/atlas_derive.py (make atlas). Do not edit.",
               "tools": tool_versions(), "builds": {}, "files": {}}
    allfiles = set()
    with tempfile.TemporaryDirectory(prefix="atlas_") as tmp:
        for b in builds:
            files, vvp, how = compile_build(b, tmp)
            inst = scope_tree(vvp, b.get("dut"))
            mods = sorted({i["module"] for i in inst})
            derived["builds"][b["id"]] = {
                k: b[k] for k in ("name", "kind", "target", "plan", "board", "top", "dut", "clock_hz", "make")
                if k in b and b[k] is not None}
            derived["builds"][b["id"]].update(
                {"how": how, "modules": mods, "instances": inst,
                 "sources": {f: sha(f) for f in files}})
            allfiles.update(files)
            print(f"  {b['id']:22s} {len(inst):4d} instances, {len(mods):3d} modules, {len(files):3d} files")
    for blk in spec.get("blocks", []):
        if blk.get("file"):
            allfiles.add(blk["file"])
    # first and last line of each block's module, for permalinks that open on it
    derived["module_lines"] = {}
    for blk in spec.get("blocks", []):
        f = blk.get("file")
        for mod in blk.get("modules", []):
            if not f or not (ROOT / f).exists():
                continue
            lines = (ROOT / f).read_text().splitlines()
            first = next((i for i, l in enumerate(lines, 1) if re.match(rf"\s*module\s+{re.escape(mod)}\b", l)), None)
            if first:
                last = next((i for i, l in enumerate(lines, 1) if i > first and re.match(r"\s*endmodule\b", l)), first)
                derived["module_lines"][mod] = {"file": f, "first": first, "last": last}
    for f in sorted(allfiles):
        if not (ROOT / f).exists():
            continue
        repo, inner, commit, dirty = last_commit(f)
        derived["files"][f] = {"sha256": sha(f), "repo": repo, "path": inner,
                               "commit": commit, "dirty": dirty}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(derived, indent=1, sort_keys=True) + "\n")
    print(f"atlas_derive: wrote {OUT.relative_to(ROOT)} ({len(builds)} builds, {len(derived['files'])} files)")


if __name__ == "__main__":
    main()
