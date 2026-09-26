#!/usr/bin/env bash
# Runs C-Node integration tests with Erlang distribution enabled
exec elixir --sname "test_$$" -S mix test --include cnode --include integration test/ex_maude/backend/cnode_integration_test.exs
