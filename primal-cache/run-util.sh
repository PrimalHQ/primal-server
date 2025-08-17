#!/usr/bin/env sh

RUST_BACKTRACE=1 cargo run --bin $1 -- --config-file ~/work/itk/primal/primal-config.json run
