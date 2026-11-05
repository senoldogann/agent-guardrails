#!/usr/bin/env bash
# Integration test: Rust template (plain libtest + proptest) through the evidence pipeline.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

new_project rust
cd "$project"
cat >Cargo.toml <<'EOF'
[package]
name = "lang_rs"
version = "0.0.0"
edition = "2024"

[dev-dependencies]
proptest = "1"

[lints.rust]
unsafe_code = "forbid"
EOF
mkdir -p src tests
cat >tests/property.rs <<'EOF'
use lang_rs::percent::{Percent, PercentError};
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
EOF

write_lib() {
  cat >src/lib.rs <<EOF
pub mod percent;

#[cfg(test)]
mod tests {
    #[test]
    $1
    fn unit_arithmetic() {
        assert_eq!(1 + 1, 2);
    }
}
EOF
}
write_lib ""

write_percent() {
  cat >src/percent.rs <<EOF
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Percent(f64);

#[derive(Debug, Clone, PartialEq)]
pub enum PercentError {
    NotFinite(f64),
    Negative(f64),
    Above100(f64),
}

impl Percent {
    pub fn new(value: f64) -> Result<Self, PercentError> {
$1
    }

    pub fn value(self) -> f64 {
        self.0
    }
}
EOF
}
write_stub() { write_percent '        let _ = value;
        todo!("NotImplemented: Percent::new")'; }
write_correct() {
  write_percent '        if !value.is_finite() {
            Err(PercentError::NotFinite(value))
        } else if value < 0.0 {
            Err(PercentError::Negative(value))
        } else if value > 100.0 {
            Err(PercentError::Above100(value))
        } else {
            Ok(Percent(value))
        }'
}
write_wrong() {
  write_percent '        if value < 0.0 { Err(PercentError::Negative(value)) } else { Ok(Percent(value.round())) }'
}
write_exit() { write_percent '        let _ = value;
        std::process::exit(0)'; }

echo "rust:"
cargo generate-lockfile -q >"$project/.setup.log" 2>&1 || {
  cat "$project/.setup.log"
  exit 1
}
write_stub
lock_tests tests/property.rs <<'EOF'
tests/property.rs::ac1_accepts_range_and_preserves_value
tests/property.rs::ac2_rejects_negative
EOF
run_red_green write_stub write_correct write_wrong

write_correct
expect_success "correct: make lint passes with the kit's clippy.toml" make --no-print-directory lint
write_lib "#[ignore]"
expect_success "ignored unit test: make test passes (exit code alone would accept it)" make --no-print-directory test
expect_failure "ignored unit test: verify-green fails" .agent/bin/verify-green "$ticket"
expect_output "ignored unit test: verify-green names it" "src/lib.rs::tests > unit_arithmetic"
write_lib ""

write_exit
expect_success "process::exit(0) in implementation: make test passes (exit code alone would accept it)" make --no-print-directory test
expect_failure "process::exit(0) in implementation: verify-green fails" .agent/bin/verify-green "$ticket"
expect_output "process::exit(0) in implementation: locked tests reported missing" "missing"
expect_failure "process::exit(0) in implementation: clippy rejects it" make --no-print-directory lint

finish rust
