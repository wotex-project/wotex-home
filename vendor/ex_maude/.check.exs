sobelow_command = [
  "bash",
  "-c",
  "mix sobelow --config --quiet --compact 2>&1 | awk '!/Sobelow cannot find the router/ && !/please use the `--router` flag/'; exit ${PIPESTATUS[0]}"
]

[
  parallel: false,
  skipped: false,
  tools: [
    {:deps_get, command: "mix deps.get"},
    {:compiler, command: "mix compile --warnings-as-errors"},
    {:c_compile, command: "make -C c_src", enabled: File.dir?("c_src")},
    {:c_test, command: "make -C c_src test", enabled: File.dir?("c_src")},
    {:formatter, command: "mix format --check-formatted"},
    {:c_format_check,
     command: "make -C c_src format-check",
     enabled: File.dir?("c_src") and System.find_executable("clang-format") != nil},
    {:rust_fmt,
     command: "cargo fmt --check",
     cd: "native/ex_maude_nif",
     enabled: File.dir?("native/ex_maude_nif") and System.find_executable("cargo") != nil},
    {:credo, command: "mix credo --strict"},
    {:sobelow, command: sobelow_command},
    {:c_lint,
     command: "make -C c_src lint",
     enabled: File.dir?("c_src") and System.find_executable("clang-tidy") != nil},
    {:rust_clippy,
     command: "cargo clippy --lib -- -D warnings",
     cd: "native/ex_maude_nif",
     enabled: File.dir?("native/ex_maude_nif") and System.find_executable("cargo") != nil},
    {:rust_test,
     command: "cargo test --locked",
     cd: "native/ex_maude_nif",
     enabled: File.dir?("native/ex_maude_nif")},
    {:rust_audit,
     command: "cargo audit", cd: "native/ex_maude_nif", enabled: File.dir?("native/ex_maude_nif")},
    {:mix_audit, command: "mix deps.audit"},
    {:hex_audit, command: "mix hex.audit"},
    {:dialyzer, command: "mix dialyzer"},
    {:doctor, command: "mix doctor --summary --raise"},
    {:ex_doc, command: ["sh", "-c", "mix docs --warnings-as-errors --formatter html >/dev/null"]},
    {:benchmark_regressions,
     command: "mix test --include benchmark test/ex_maude/benchmark_regression_test.exs"},
    {:ex_unit, command: "mix test --cover"},
    {:test_nif, command: "mix test.nif"},
    {:test_cnode, command: "mix test.cnode", enabled: File.exists?("priv/maude_bridge")}
  ]
]
