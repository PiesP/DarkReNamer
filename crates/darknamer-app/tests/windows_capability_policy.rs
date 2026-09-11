#[path = "support/windows_capabilities.rs"]
mod windows_capabilities;
#[path = "support/workflow_policy.rs"]
mod workflow_policy;

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
fn hosted_windows_and_release_gates_require_capabilities_with_visible_output() -> Result<(), String>
{
    workflow_policy::validate_hosted_capability_gates()
}

#[test]
fn release_workflows_promote_the_immutable_candidate_without_rebuilding() -> Result<(), String> {
    workflow_policy::validate_release_handoff_policy()
}

#[test]
fn experimental_workflows_are_manual_least_privilege_and_non_publishing() -> Result<(), String> {
    workflow_policy::validate_experimental_workflows()
}
