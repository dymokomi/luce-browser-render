#!/usr/bin/env python3
"""Build and run the rasterizer's integration tests (tiny-skia's suite, tests/raster).

Usage: tests/run_raster.py [--no-build] [--backend=c] [test_name ...]

Builds tests/raster/run.lucb into build/run_raster and runs it from the repository root.
Every test renders with the raster module and compares against tiny-skia's reference image
pixel for pixel; a failure writes the actual image to build/raster-failures/. When the runner
itself traps, each test is rerun on its own to name the ones that trap.
"""
import os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXE = os.path.join(ROOT, "build", "run_raster")

def build(extra):
    os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
    print("building build/run_raster ...", flush=True)
    result = subprocess.run(["luce-base", "build", "tests/raster/run.lucb", "-o", EXE, *extra], cwd=ROOT)
    if result.returncode != 0:
        print("FAIL: cannot build the raster test runner")
        sys.exit(1)

def main():
    args = sys.argv[1:]
    no_build = "--no-build" in args
    extra = [a for a in args if a.startswith("--backend")]
    names = [a for a in args if not a.startswith("--")]
    if not no_build:
        build(extra)
    result = subprocess.run([EXE, *names], cwd=ROOT)
    if result.returncode in (0, 1):
        sys.exit(result.returncode)
    # The runner trapped: run the tests one by one to name the ones that trap.
    print(f"the runner stopped with status {result.returncode}; running the tests one by one", flush=True)
    listed = subprocess.run([EXE, "--list"], cwd=ROOT, capture_output=True, text=True).stdout.split()
    failed = []
    for name in (names or listed):
        r = subprocess.run([EXE, name], cwd=ROOT, capture_output=True, text=True)
        if r.returncode != 0:
            failed.append(name)
            print(f"FAIL  {name} (status {r.returncode})")
            sys.stdout.write(r.stdout[-2000:])
            sys.stdout.write(r.stderr[-2000:])
    print(f"{len(failed)} failed")
    sys.exit(1)

main()
