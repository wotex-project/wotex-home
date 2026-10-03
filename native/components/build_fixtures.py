#!/usr/bin/env python3
"""Build independent one-shot test components with a pinned wasm-tools CLI."""
import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument("--wasm-tools", required=True, type=Path)
args = parser.parse_args()
tool = args.wasm_tools.resolve()
version = subprocess.check_output([str(tool), "--version"], text=True).strip()
if version.split()[:2] != ["wasm-tools", "1.261.0"]:
    raise SystemExit(f"expected wasm-tools 1.261.0, got {version}")
out = ROOT / "_build/component-fixtures"
out.mkdir(parents=True, exist_ok=True)
base = (HERE / "examples/reference/profile.wat").read_text()


def run(*arguments):
    subprocess.run([str(tool), *map(str, arguments)], check=True)


def component(name, wat):
    source = out / f"{name}.wat"
    source.write_text(wat)
    embedded = out / f"{name}.core.wasm"
    run("component", "embed", HERE / "wit/profile.wit", source,
        "--world", "profile", "-o", embedded)
    run("component", "new", embedded, "-o", out / f"{name}.wasm")
    run("validate", out / f"{name}.wasm")


component("reference", base)
component("init-loop", base.replace("(func (;5;) (type 4))", "(func (;5;) (type 4) (loop $l br $l))"))
component("call-loop", base.replace("(local $power i32)", "(local $power i32) (loop $l br $l)"))
component("trap", base.replace("(local $power i32)", "(local $power i32) unreachable"))
component("memory", base.replace("(local $power i32)", "(local $power i32) i32.const 1000 memory.grow drop"))
component("dishonest", base.replace("i32.const 260 i32.const 6 i32.store", "i32.const 260 i32.const 5 i32.store"))
component("oversized", base.replace("i32.const 260 i32.const 6 i32.store", "i32.const 260 i32.const 2147483647 i32.store"))
component("invalid-bool", base.replace("i32.const 257 local.get $power i32.const 65535 i32.eq i32.store8", "i32.const 257 i32.const 2 i32.store8"))
# Add a hidden state cell; one-shot execution must not retain it across requests.
stateful = base.replace("(local $power i32)", "(local $power i32)\n    i32.const 300 i32.const 300 i32.load i32.const 1 i32.add i32.store")
stateful = stateful.replace("i32.const 256\n  )", "i32.const 300 i32.load i32.const 1 i32.gt_u if unreachable end\n    i32.const 256\n  )", 1)
component("stateful", stateful)
component("compile-heavy", base.replace("(func (;5;) (type 4))", "(func (;5;) (type 4) " + "nop " * 450000 + ")"))
component("lying-decoder", base.replace("i32.const 257 local.get $power i32.const 65535 i32.eq i32.store8", "i32.const 257 i32.const 0 i32.store8"))
printed = subprocess.check_output([str(tool), "print", str(out / "reference.wasm")], text=True)
init_printed = subprocess.check_output([str(tool), "print", str(out / "init-loop.wasm")], text=True)
for name, source in [
    ("wrong-types", printed.replace('(param "power" bool)', '(param "power" u8)')),
    ("wrong-types-init", init_printed.replace('(param "power" bool)', '(param "power" u8)')),
    ("extra-export", printed.rsplit(")", 1)[0] + '(export "extra" (type 0)))'),
    ("extra-interface", printed.replace('    (export (;3;) "encode-power" (func 1) (func (type 11)))',
        '    (export (;3;) "encode-power" (func 1) (func (type 11)))\n    (export "extra" (func 1))')),
]:
    wat_file = out / f"{name}.wat"
    wat_file.write_text(source)
    run("parse", wat_file, "-o", out / f"{name}.wasm")
    run("validate", out / f"{name}.wasm")
for name, wat in [("wrong-world", "(component)"), ("imports", '(component (import "ambient" (func)))')]:
    source = out / f"{name}.wat"
    source.write_text(wat)
    run("parse", source, "-o", out / f"{name}.wasm")
rust_core = ROOT / "_build/component-example/wasm32-unknown-unknown/release/woh_light_power_example.wasm"
if not rust_core.is_file():
    raise SystemExit("build the locked Rust author example first")
run("component", "new", rust_core, "-o", out / "rust.wasm")
run("validate", out / "rust.wasm")
print(f"Built 18 component fixtures in {out}")
