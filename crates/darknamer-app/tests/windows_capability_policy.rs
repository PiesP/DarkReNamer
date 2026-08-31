#[path = "support/source_root.rs"]
mod source_root;
#[path = "support/windows_capabilities.rs"]
mod windows_capabilities;

use std::ffi::OsStr;
use std::fs;
use std::io;
use std::path::Path;

use windows_capabilities::{GateMode, gate_mode_from, unavailable_in_mode};

#[test]
fn privilege_not_held_is_a_symlink_creation_capability_error() {
    let error = io::Error::from_raw_os_error(1_314);

    assert!(windows_capabilities::is_symlink_creation_capability_error(
        &error
    ));
}

#[test]
fn explicit_test_source_root_replaces_the_embedded_build_path()
-> Result<(), Box<dyn std::error::Error>> {
    let fixture = tempfile::tempdir()?;
    let repository = fixture.path();
    fs::create_dir_all(repository.join(".github/workflows"))?;
    fs::create_dir_all(repository.join("crates/darknamer-app"))?;
    fs::write(repository.join("Cargo.toml"), b"[workspace]\n")?;
    fs::write(repository.join(".github/workflows/ci.yaml"), b"name: CI\n")?;
    fs::write(
        repository.join("crates/darknamer-app/Cargo.toml"),
        b"[package]\nname = \"darknamer-app\"\n",
    )?;

    let resolved = source_root::repository_root_from(
        Some(repository.as_os_str()),
        Path::new("/missing/wsl-build/crates/darknamer-app"),
    )?;

    assert_eq!(resolved, repository);
    Ok(())
}

#[test]
fn explicit_test_source_root_without_repository_markers_fails_closed()
-> Result<(), Box<dyn std::error::Error>> {
    let fixture = tempfile::tempdir()?;

    let error = source_root::repository_root_from(
        Some(fixture.path().as_os_str()),
        Path::new("/missing/wsl-build/crates/darknamer-app"),
    )
    .err()
    .ok_or_else(|| io::Error::other("invalid test source root was accepted"))?;

    assert_eq!(error.kind(), io::ErrorKind::NotFound);
    assert!(error.to_string().contains("repository marker"));
    Ok(())
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
    let repository = source_root::repository_root()?;
    for workflow in [
        ".github/workflows/ci.yaml",
        ".github/workflows/release.yaml",
    ] {
        let source = fs::read_to_string(repository.join(workflow))?;
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
