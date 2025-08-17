#!/usr/bin/env sh

RUST_BACKTRACE=1 RUSTFLAGS="-Awarnings --cfg tokio_unstable --cfg tokio_taskdump" cargo build --release

