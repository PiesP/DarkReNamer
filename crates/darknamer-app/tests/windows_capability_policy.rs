#[path = "support/windows_capabilities.rs"]
mod windows_capabilities;

use std::ffi::OsStr;
use std::io;

use windows_capabilities::{GateMode, gate_mode_from, unavailable_in_mode};

#[test]
fn privilege_not_held_is_a_symlink_creation_capability_error() {
    let error = io::Error::from_raw_os_error(1_314);

    assert!(windows_capabilities::is_symlink_creation_capability_error(
        &error
    ));
}

#[test]
fn local_optional_mode_emits_an_explicit_skip_outcome() {
    assert!(gate_mode_from(None).is_ok_and(|mode| mode == GateMode::LocalOptional));
    assert!(
        unavailable_in_mode(
            GateMode::LocalOptional,
            "symlink-creation",
            Some(5),
            "permission-denied"
        )
        .is_ok()
    );
}

#[test]
fn required_mode_turns_unavailable_capabilities_into_gate_failures() {
    assert!(gate_mode_from(Some(OsStr::new("1"))).is_ok_and(|mode| mode == GateMode::Required));
    let message = unavailable_in_mode(
        GateMode::Required,
        "case-sensitive-query",
        Some(120),
        "unsupported",
    )
    .err()
    .map(|error| error.to_string());
    assert_eq!(
        message.as_deref(),
        Some(
            "required Windows backend capability unavailable: capability=case-sensitive-query os_code=120 reason=unsupported; DARKRENAMER_REQUIRE_WINDOWS_BACKEND_CAPABILITIES=1"
        )
    );
}

#[test]
fn invalid_required_mode_configuration_fails_closed() {
    let message = gate_mode_from(Some(OsStr::new("true")))
        .err()
        .map(|error| error.to_string());
    assert_eq!(
        message.as_deref(),
        Some("DARKRENAMER_REQUIRE_WINDOWS_BACKEND_CAPABILITIES must be unset or exactly 1")
    );
}

#[test]
fn hosted_windows_and_release_gates_require_capabilities_with_visible_output()
-> Result<(), Box<dyn std::error::Error>> {
    for (workflow, source) in [
        (
            ".github/workflows/ci.yaml",
            include_str!("../../../.github/workflows/ci.yaml"),
        ),
        (
            ".github/workflows/release.yaml",
            include_str!("../../../.github/workflows/release.yaml"),
        ),
    ] {
        assert!(
            source.contains("DARKRENAMER_REQUIRE_WINDOWS_BACKEND_CAPABILITIES = '1'"),
            "{workflow} must enable required Windows backend capabilities"
        );
        assert!(
            source.contains(
                "cargo test --workspace --all-targets --all-features --locked -- --nocapture"
            ),
            "{workflow} must retain capability output in the hosted log"
        );
    }
    Ok(())
}
