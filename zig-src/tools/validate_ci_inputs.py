#!/usr/bin/env python3
"""Validate the two minimal-build workflows after the 2026-10-18 hardening.

Checks, per workflow file:
  1. YAML parses, and no duplicate keys (GitHub silently takes the last one).
  2. Every step's `run:` script passes `bash -n` (GitHub expressions masked).
  3. `env:` values reference only known contexts.

Then a behavioural simulation of the "Normalize inputs" step:
  - push case: every input empty -> defaults must be applied, no error.
  - dispatch defaults: same result.
  - explicit all/false: must be preserved verbatim.
  - bad arch / bad boolean: must exit non-zero with ::error::.
And a simulation of the overlay trimming-consistency assertion against
build/overlay/meta.json fixtures.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))  # zig-src/tools/ -> 仓库根
WF = [
    os.path.join(ROOT, ".github", "workflows", "build_go_minimal.yml"),
    os.path.join(ROOT, ".github", "workflows", "build_zig_minimal.yml"),
]

EXPR = re.compile(r"\$\{\{[^}]*\}\}")


class UniqueKeyLoader(yaml.SafeLoader):
    pass


def no_dup_keys(loader, node, deep=False):
    mapping = {}
    for k_node, v_node in node.value:
        k = loader.construct_object(k_node, deep=deep)
        if k in mapping:
            raise ValueError(f"duplicate key {k!r} at line {k_node.start_mark.line + 1}")
        mapping[k] = loader.construct_object(v_node, deep=deep)
    return mapping


UniqueKeyLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, no_dup_keys)

failures = []


def sh(script: str, env=None, cwd=None) -> subprocess.CompletedProcess:
    e = dict(os.environ)
    e.update(env or {})
    return subprocess.run(["bash", "-c", script], env=e, cwd=cwd,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def extract_runs(doc):
    """Yield (job_id, step_name, run_text, env_map) for every step."""
    for job_id, job in (doc.get("jobs") or {}).items():
        for step in job.get("steps") or []:
            if "run" in step:
                yield job_id, step.get("name", "<unnamed>"), step["run"], step.get("env") or {}


def mask(script: str) -> str:
    return EXPR.sub("GHEXPR", script)


for path in WF:
    rel = os.path.relpath(path, ROOT)
    print(f"== {rel} ==")
    try:
        with open(path, encoding="utf-8") as f:
            doc = yaml.load(f, Loader=UniqueKeyLoader)
    except Exception as e:  # noqa: BLE001
        failures.append(f"{rel}: YAML parse failed: {e}")
        print(f"  YAML FAIL: {e}")
        continue
    print("  YAML OK (no duplicate keys)")

    # defaults.run.working-directory presence
    wd = ((doc.get("defaults") or {}).get("run") or {}).get("working-directory")
    if "zig" in rel:
        if wd != "zig-src":
            failures.append(f"{rel}: expected defaults.run.working-directory=zig-src, got {wd!r}")
            print(f"  defaults FAIL: {wd!r}")
        else:
            print("  defaults.run.working-directory = zig-src OK")

    n = 0
    for job_id, name, script, env in extract_runs(doc):
        n += 1
        with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False, encoding="utf-8") as tf:
            tf.write(mask(script))
            tmp = tf.name
        r = sh(f"bash -n {tmp!r}")
        os.unlink(tmp)
        if r.returncode != 0:
            failures.append(f"{rel}:{job_id}/{name}: bash -n failed: {r.stdout.strip()}")
            print(f"  bash -n FAIL [{job_id}/{name}]:\n{r.stdout}")
    print(f"  bash -n OK on {n} run steps")

    # env blocks must not reference inputs.* in run-consuming steps anymore.
    # The "Normalize inputs" step is the single sanctioned exception: it is
    # precisely the one place that reads inputs.* and tames them.
    for job_id, name, script, env in extract_runs(doc):
        if name.startswith("Normalize inputs"):
            continue
        for k, v in env.items():
            if isinstance(v, str) and "inputs." in v and "build_sqfs" in job_id:
                failures.append(f"{rel}:{job_id}/{name}: env {k} still maps ${{{{ inputs.* }}}}")
                print(f"  inputs leak FAIL [{job_id}/{name}] {k}={v!r}")
    print("  no unexpected inputs.* env leaks in build_sqfs OK")


# ---------------------------------------------------------------------------
# Behavioural simulation: the Normalize inputs step of build_sqfs
# ---------------------------------------------------------------------------
print("== Normalize inputs simulation ==")
with open(WF[0], encoding="utf-8") as f:
    go_doc = yaml.load(f, Loader=UniqueKeyLoader)
steps = {s.get("name"): s for s in go_doc["jobs"]["build_sqfs"]["steps"]}
norm = steps["Normalize inputs (push runs see empty inputs)"]["run"]
env_map = steps["Normalize inputs (push runs see empty inputs)"]["env"]
print(f"  extracted {len(norm)} chars, env keys: {sorted(env_map)}")

ALL_DEFAULTS = {
    "DRIVERS": "local,webdav,itvsh,aliyundrive_open,189,189pc,123,quark_uc,115,wopan,strm",
    "STRIP_OFFLINE": "true",
    "STRIP_FFMPEG": "true",
    "DB_BACKENDS": "sqlite",
    "SEARCH_BACKENDS": "all",
    "STRIP_PROTOCOLS": "none",
    "ARCH": "linux-arm64",
    "CDN": "https://cdn.jsdelivr.net/npm/@openlist-frontend/openlist-frontend@latest/dist",
    "COMPRESS": "xz -b 1M -all-root",
}


def run_norm(values: dict):
    with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as tf:
        gev = tf.name
    e = {k: "" for k in env_map}
    e.update(values)
    e["GITHUB_ENV"] = gev
    r = sh(norm, env=e)
    out = {}
    with open(gev, encoding="utf-8") as f:
        for line in f:
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1)
                out[k] = v
    os.unlink(gev)
    return r, out


# push case: everything empty
r, out = run_norm({})
if r.returncode != 0:
    failures.append(f"normalize push-case exited {r.returncode}: {r.stdout}")
    print(f"  push-case FAIL:\n{r.stdout}")
elif out != ALL_DEFAULTS:
    failures.append(f"normalize push-case wrong output: {out}")
    print(f"  push-case FAIL: {out}")
else:
    print("  push case (all inputs empty) -> defaults applied OK")

# dispatch defaults: same values as the workflow_dispatch default: fields
r, out = run_norm({
    "DRIVERS": ALL_DEFAULTS["DRIVERS"],
    "STRIP_OFFLINE": "true",
    "STRIP_FFMPEG": "true",
    "DB_BACKENDS": "sqlite",
    "SEARCH_BACKENDS": "all",
    "STRIP_PROTOCOLS": "none",
    "ARCH": "linux-arm64",
    "CDN": ALL_DEFAULTS["CDN"],
})
if r.returncode != 0 or out.get("DRIVERS") != ALL_DEFAULTS["DRIVERS"] or out.get("ARCH") != "linux-arm64":
    failures.append(f"normalize dispatch-case wrong: rc={r.returncode} {out}")
    print(f"  dispatch-case FAIL: {out}")
else:
    print("  dispatch case (explicit defaults) -> passthrough OK")

# explicit all / false must survive (the || trap would break these with the
# naive one-liner approach: false || true == true in GitHub expressions)
r, out = run_norm({"DRIVERS": "all", "STRIP_OFFLINE": "false", "STRIP_FFMPEG": "false",
                   "DB_BACKENDS": "sqlite,mysql", "ARCH": "linux-armv7"})
ok = (r.returncode == 0 and out.get("DRIVERS") == "all"
      and out.get("STRIP_OFFLINE") == "false" and out.get("STRIP_FFMPEG") == "false"
      and out.get("DB_BACKENDS") == "sqlite,mysql" and out.get("ARCH") == "linux-armv7")
if not ok:
    failures.append(f"normalize explicit-case wrong: rc={r.returncode} {out}\n{r.stdout}")
    print(f"  explicit-case FAIL: {out}")
else:
    print("  explicit all/false/armv7 preserved OK (no || truthiness trap)")

# bad inputs must fail loudly
for bad_label, bad_vals in [
    ("bad arch", {"ARCH": "darwin-arm64"}),
    ("empty-ish arch via case fallthrough", {"ARCH": ""}),  # becomes default -> ok, excluded below
    ("bad boolean", {"STRIP_FFMPEG": "yes"}),
]:
    if bad_label.startswith("empty-ish"):
        continue
    r, out = run_norm(bad_vals)
    if r.returncode == 0:
        failures.append(f"normalize {bad_label} did NOT fail")
        print(f"  {bad_label} FAIL: exited 0")
    elif "::error::" not in r.stdout:
        failures.append(f"normalize {bad_label} failed without ::error::")
        print(f"  {bad_label} FAIL: no ::error:: annotation")
    else:
        print(f"  {bad_label} -> hard fail OK ({r.stdout.strip().splitlines()[-1][:80]})")


# ---------------------------------------------------------------------------
# Behavioural simulation: the trimming-consistency assertion (overlay step)
# ---------------------------------------------------------------------------
print("== trimming assertion simulation ==")
m = re.search(r"python3 - <<'PY'\n(.*?)\n\s*PY\n", norm_step_for_assert :=
              {s.get("name"): s for s in go_doc["jobs"]["build_sqfs"]["steps"]}
              ["Generate build overlay"]["run"], re.S)
assert m, "trimming assertion heredoc not found in overlay step"
py_src = m.group(1)
print(f"  extracted {len(py_src)} chars of python")

with tempfile.TemporaryDirectory() as td:
    build_dir = os.path.join(td, "build", "overlay")
    os.makedirs(build_dir)

    def run_assert(meta: dict, drivers_env: str):
        with open(os.path.join(build_dir, "meta.json"), "w", encoding="utf-8") as f:
            json.dump(meta, f)
        # the workflow feeds the body to `python3 - <<'PY'`; replay that shape,
        # with this validator's own interpreter standing in for python3
        # (forward slashes: bash eats backslashes in the Windows path)
        py = sys.executable.replace("\\", "/")
        script = f"{py} - <<'PY'\n{py_src}\nPY\n"
        return sh(script, env={"DRIVERS": drivers_env}, cwd=td)

    r = run_assert({"drivers": ["local"], "drivers_full": False, "rewrites": ["drivers/all.go"]},
                   "local,webdav")
    print("  specific list + full=false ->", "OK" if r.returncode == 0 else f"FAIL {r.stdout}",
          f"({r.stdout.strip().splitlines()[-1][:60]})" if r.returncode == 0 else "")
    if r.returncode != 0:
        failures.append("trimming assert: false positive on consistent meta")

    r = run_assert({"drivers": ["local"] * 87, "drivers_full": True, "rewrites": []}, "all")
    if r.returncode != 0:
        failures.append(f"trimming assert: false positive on all/full: {r.stdout}")
        print(f"  all + full=true FAIL: {r.stdout}")
    else:
        print("  all + full=true -> OK")

    r = run_assert({"drivers": ["local"] * 87, "drivers_full": True, "rewrites": []}, "local,webdav")
    if r.returncode == 0 or "::error::" not in r.stdout:
        failures.append(f"trimming assert: did not catch the accident: {r.stdout}")
        print(f"  accident replay FAIL: {r.stdout}")
    else:
        print("  accident replay (specific list + full=true) -> hard fail OK")

print()
if failures:
    print("FAILURES:")
    for f_ in failures:
        print(" -", f_)
    sys.exit(1)
print("ALL CHECKS PASSED")
