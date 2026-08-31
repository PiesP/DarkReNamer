use std::env;
use std::ffi::OsStr;
use std::io;

pub const REQUIRED_CAPABILITIES_ENV: &str = "DARKRENAMER_REQUIRE_WINDOWS_BACKEND_CAPABILITIES";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum GateMode {
    LocalOptional,
    Required,
}

pub fn gate_mode_from(value: Option<&OsStr>) -> io::Result<GateMode> {
    match value {
        None => Ok(GateMode::LocalOptional),
        Some(value) if value == "1" => Ok(GateMode::Required),
        Some(_) => Err(io::Error::other(format!(
            "{REQUIRED_CAPABILITIES_ENV} must be unset or exactly 1"
        ))),
    }
}

#[allow(
    dead_code,
    reason = "the cross-platform policy target tests pure decisions while Windows targets call this environment boundary"
)]
pub fn unavailable(capability: &str, os_code: Option<i32>, reason: &str) -> io::Result<()> {
    let mode = gate_mode_from(env::var_os(REQUIRED_CAPABILITIES_ENV).as_deref())?;
    unavailable_in_mode(mode, capability, os_code, reason)
}

pub fn unavailable_in_mode(
    mode: GateMode,
    capability: &str,
    os_code: Option<i32>,
    reason: &str,
) -> io::Result<()> {
    let os_code = os_code.map_or_else(|| "none".to_owned(), |code| code.to_string());
    match mode {
        GateMode::LocalOptional => {
            eprintln!(
                "DARKRENAMER_WINDOWS_CAPABILITY_SKIP capability={capability} os_code={os_code} reason={reason} mode=local-optional"
            );
            Ok(())
        }
        GateMode::Required => Err(io::Error::other(format!(
            "required Windows backend capability unavailable: capability={capability} os_code={os_code} reason={reason}; {REQUIRED_CAPABILITIES_ENV}=1"
        ))),
    }
}
