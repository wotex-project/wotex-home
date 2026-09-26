#!/usr/bin/env bash
# Runs backend benchmarks with Erlang distribution enabled for C-Node support
exec elixir --sname "bench_$$" -S mix run bench/backends_bench.exs
