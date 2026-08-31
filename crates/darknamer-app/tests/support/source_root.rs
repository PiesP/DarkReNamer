use std::env;
use std::ffi::OsStr;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

pub const TEST_SOURCE_ROOT_ENV: &str = "DARKRENAMER_TEST_SOURCE_ROOT";
const REPOSITORY_MARKERS: &[&str] = &[
    "Cargo.toml",
    ".github/workflows/ci.yaml",
    "crates/darknamer-app/Cargo.toml",
];

pub fn repository_root() -> io::Result<PathBuf> {
    repository_root_from(
        env::var_os(TEST_SOURCE_ROOT_ENV).as_deref(),
        Path::new(env!("CARGO_MANIFEST_DIR")),
    )
}

pub fn repository_root_from(
    runtime_root: Option<&OsStr>,
    embedded_manifest_dir: &Path,
) -> io::Result<PathBuf> {
    let root = if let Some(runtime_root) = runtime_root {
        if runtime_root.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("{TEST_SOURCE_ROOT_ENV} must not be empty"),
            ));
        }
        PathBuf::from(runtime_root)
    } else {
        embedded_manifest_dir
            .parent()
            .and_then(Path::parent)
            .map(Path::to_path_buf)
            .ok_or_else(|| io::Error::other("embedded repository root is unavailable"))?
    };
    if !root.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("test source root must be absolute: {}", root.display()),
        ));
    }
    for marker in REPOSITORY_MARKERS {
        let path = root.join(marker);
        let metadata = fs::metadata(&path).map_err(|error| {
            io::Error::new(
                error.kind(),
                format!(
                    "test source root is missing repository marker {}: {error}",
                    path.display()
                ),
            )
        })?;
        if !metadata.is_file() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!(
                    "test source root repository marker is not a file: {}",
                    path.display()
                ),
            ));
        }
    }
    Ok(root)
}
