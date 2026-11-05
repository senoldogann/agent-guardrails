# Rust spec patterns

Tools: cargo check/clippy (`-D warnings`), rustfmt, proptest, plain libtest (not nextest: under
nextest a test that calls `process::exit(0)` is reported as passed). Clippy runs with
`.agent/lint/clippy.toml`, which disallows `process::exit`/`abort`, environment mutation and panic
hooks. `Cargo.toml` (human-owned) sets `[lints.rust] unsafe_code = "forbid"`.
Rust gives the real guarantee: a tuple struct with a private field can only be built inside its
module and its child modules.

## Contract (locked): `src/domain/percent/mod.rs`

Uses `thiserror`; the spec lists `thiserror = "2"` under `[dependencies]` as a Cargo.toml change for
human review, or the contract implements `Display` and `std::error::Error` by hand.

```rust
mod imp; // implementation lives in a child module so it can reach the private field

/// A percentage in [0, 100]. Only `Percent::new` produces one.
#[derive(Debug, Clone, Copy, PartialEq, PartialOrd)]
pub struct Percent(f64);

#[derive(Debug, Clone, PartialEq, thiserror::Error)]
pub enum PercentError {
    #[error("percent must be finite, got {0}")]
    NotFinite(f64),
    #[error("percent must be >= 0, got {0}")]
    Negative(f64),
    #[error("percent must be <= 100, got {0}")]
    Above100(f64),
}

/// Signatures the implementation must provide.
pub trait PercentContract: Sized {
    fn new(value: f64) -> Result<Self, PercentError>;
    fn value(self) -> f64;
}
```

## Implementation stub (write-allowed): `src/domain/percent/imp.rs`

The message must start with `NotImplemented:` (the spec gate checks every locked test fails with it).

```rust
use super::{Percent, PercentContract, PercentError};

impl PercentContract for Percent {
    fn new(_value: f64) -> Result<Self, PercentError> {
        todo!("NotImplemented: Percent::new")
    }
    fn value(self) -> f64 {
        todo!("NotImplemented: Percent::value")
    }
}
```

## Property test (locked): `tests/property.rs`

- Name every test `ac<n>_<behaviour>`, one criterion per test; the ID is `tests/property.rs::<fn>`
  (module paths joined with ` > `).
- Pin the run configuration with `#![proptest_config(...)]` in every `proptest!` block.

```rust
use my_crate::domain::percent::{Percent, PercentContract, PercentError};
use proptest::prelude::*;

proptest! {
    #![proptest_config(ProptestConfig { cases: 200, failure_persistence: None, ..ProptestConfig::default() })]

    #[test]
    fn ac1_accepts_range_and_preserves_value(v in 0.0f64..=100.0) {
        prop_assert_eq!(Percent::new(v).map(Percent::value), Ok(v));
    }

    #[test]
    fn ac2_rejects_negative(v in f64::MIN..-f64::MIN_POSITIVE) {
        prop_assert_eq!(Percent::new(v), Err(PercentError::Negative(v)));
    }
}
```

Edge values as plain `#[test]` functions of the criterion they belong to: `0.0`, `-0.0`, `100.0`
(AC-1), `100.0 + f64::EPSILON * 100.0` (above-100), `f64::NAN`, `f64::INFINITY` (not-finite).
Prefer integer-backed types (e.g. basis points `u16`, money in minor units `i64`) when the ticket allows;
ask in open questions.

## Acceptance

One `#[test]` per acceptance scenario in `tests/acceptance.rs` (locked), named `ac<n>_<scenario>`,
with Given/When/Then as comments. A `specs/<ID>/*.feature` file is optional documentation; the kit
ships no Gherkin runner.
