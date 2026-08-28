//! Filesystem admission and transaction boundary.

#![forbid(unsafe_code)]

/// Returns the linked planning-core version.
#[must_use]
pub const fn core_version() -> &'static str {
    dark_renamer_core::version()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn links_the_planning_core() {
        assert_eq!(core_version(), "0.1.0");
    }
}
