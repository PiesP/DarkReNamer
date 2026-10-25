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
fn ci_caches_exact_security_tool_versions_only_in_the_security_job() -> Result<(), String> {
    workflow_policy::validate_ci_security_tools_cache()?;
    let original = include_str!("../../../.github/workflows/ci.yaml");
    for mutation in [
        original.replace(
            "run: python3 scripts/run-scheduled-rust-audit.py --emit-pins",
            "run: python3 scripts/run-scheduled-rust-audit.py --emit-pins || true",
        ),
        original.replace("id: scanner-pins", "id: unchecked-pins"),
        original.replace(
            "      - name: Restore pinned Rust security tools\n",
            "      - name: Duplicate scanner selection\n        run: python3 scripts/run-scheduled-rust-audit.py --emit-pins\n\n      - name: Restore pinned Rust security tools\n",
        ),
        original.replace(
            "hashFiles('config/release-tool-integrity.json', 'config/cargo-audit-0.22.2-patched.lock', 'scripts/build-patched-cargo-audit.py')",
            "steps.scanner-pins.outputs.audit-version",
        ),
        original.replace("'config/cargo-audit-0.22.2-patched.lock', ", ""),
        original.replace(
            "DENY_VERSION: ${{ steps.scanner-pins.outputs.deny-version }}",
            "DENY_VERSION: ${{ github.event.inputs.deny_version }}",
        ),
        original.replace(
            "python3 scripts/build-patched-cargo-audit.py --destination",
            "python3 scripts/build-patched-cargo-audit.py --verify-only --destination",
        ),
        original.replace(
            "--destination \"$SECURITY_TOOLS_ROOT/bin\"",
            "--destination \"$GITHUB_WORKSPACE/bin\"",
        ),
        original.replace(
            "cargo-deny --version \"$DENY_VERSION\"",
            "cargo-deny --version \"$DENY_VERSION\" || true",
        ),
        original.replace(
            "cargo install --locked --root \"$SECURITY_TOOLS_ROOT\" cargo-deny",
            "cargo install --root \"$SECURITY_TOOLS_ROOT\" cargo-deny",
        ),
    ] {
        assert_ne!(mutation, original, "security-pin fixture did not change CI");
        assert!(
            workflow_policy::validate_ci_security_tools_cache_source(&mutation).is_err(),
            "unsafe security-pin mutation was accepted"
        );
    }
    Ok(())
}

#[test]
fn ci_document_routing_preserves_required_gates_and_fails_closed() -> Result<(), String> {
    workflow_policy::validate_ci_docs_routing()?;
    let original = include_str!("../../../.github/workflows/ci.yaml");
    for changed in [
        original.replace("if: ${{ !cancelled() }}", "if: ${{ success() }}"),
        original.replace("needs: [classify]", "needs: []"),
        original.replace(
            "(needs.classify.result != 'success' || needs.classify.outputs.docs_only != 'true')",
            "needs.classify.outputs.docs_only != 'true'",
        ),
        original.replace(
            "      - name: Enforce the Rust-only source tree\n        id: inventory\n        if: ${{ !cancelled() && steps.checkout.outcome == 'success' }}",
            "      - name: Enforce the Rust-only source tree\n        id: inventory\n        if: false",
        ),
        original.replace(
            "python3 scripts/run-scheduled-rust-audit.py",
            "echo skipped-advisory-check",
        ),
    ] {
        assert!(
            workflow_policy::validate_ci_docs_routing_source(&changed).is_err()
                || workflow_policy::validate_ci_security_tools_cache_source(&changed).is_err(),
            "unsafe CI routing or security mutation was accepted"
        );
    }
    Ok(())
}

#[test]
fn ci_tooling_scope_requires_manual_all_and_ordinary_current_on_both_hosts() -> Result<(), String> {
    let original = include_str!("../../../.github/workflows/ci.yaml");
    workflow_policy::validate_ci_docs_routing_source(original)?;
    let selector = "${{ github.event_name == 'workflow_dispatch' && 'All' || 'Current' }}";
    let mut changed = vec![
        original.replace(selector, "${{ github.event_name == 'workflow_dispatch' && 'Current' || 'Current' }}"),
        original.replace(selector, "${{ github.event_name == 'workflow_dispatch' && 'All' || 'All' }}"),
        original.replace(selector, "Current"),
        original.replace(
            "    name: pr-gate/quality\n    needs: [classify]",
            "    name: pr-gate/quality\n    env:\n      TOOLING_TEST_SCOPE: Current\n    needs: [classify]",
        ),
    ];
    for platform in ["Ubuntu", "Windows"] {
        let command = format!(
            "run: ./scripts/test-tooling.ps1 -Platform {platform} -Scope $env:TOOLING_TEST_SCOPE"
        );
        changed.extend([
            original.replace(&command, &format!("run: ./scripts/test-tooling.ps1 -Platform {platform}")),
            original.replace(&command, &format!("run: ./scripts/test-tooling.ps1 -Platform {platform} -Scope Current")),
            original.replace(&command, "run: Write-Host 'tooling suite omitted'"),
            original.replace(
                &format!("shell: pwsh\n        {command}"),
                &format!("shell: pwsh\n        env:\n          TOOLING_TEST_SCOPE: Current\n        {command}"),
            ),
        ]);
    }
    for mutation in changed {
        assert_ne!(
            mutation, original,
            "tooling-scope fixture did not change CI"
        );
        assert!(
            workflow_policy::validate_ci_docs_routing_source(&mutation).is_err(),
            "unsafe tooling-scope mutation was accepted"
        );
    }
    Ok(())
}

#[test]
fn release_workflows_promote_the_immutable_candidate_without_rebuilding() -> Result<(), String> {
    workflow_policy::validate_release_handoff_policy()
}

#[test]
fn experimental_workflows_are_manual_least_privilege_and_non_publishing() -> Result<(), String> {
    workflow_policy::validate_experimental_workflows()
}
