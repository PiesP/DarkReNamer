//! Test-only process-exit seams for source-bound crash recovery tests.

pub(crate) fn hit(point: &str) {
    let child_mode = std::env::var("DARKRENAMER_TEST_CHILD_MODE").as_deref() == Ok("1");
    if child_mode && std::env::var("DARKRENAMER_TEST_CRASH_POINT").as_deref() == Ok(point) {
        std::process::exit(86);
    }
}
