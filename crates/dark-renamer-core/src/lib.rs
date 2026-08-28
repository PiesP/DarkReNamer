//! Portable rename rules and deterministic planning.

#![forbid(unsafe_code)]

/// Returns the workspace version of the core crate.
#[must_use]
pub const fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exposes_workspace_version() {
        assert_eq!(version(), "0.1.0");
    }
}
