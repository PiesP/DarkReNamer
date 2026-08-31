use std::fs;
use std::io;
use std::path::{Component, Path, PathBuf};

pub(crate) fn render(root: &Path) -> io::Result<String> {
    let mut files = Vec::new();
    collect_rust_files(root, &mut files)?;
    let mut files = files
        .into_iter()
        .map(|file| normalized_relative_path(root, &file).map(|relative| (relative, file)))
        .collect::<io::Result<Vec<_>>>()?;
    files.sort_by(|left, right| left.0.cmp(&right.0));

    let mut source = String::from("const BUILD_SOURCE_FILES: &[(&str, &str)] = &[\n");
    for (relative, file) in files {
        let contents = fs::read_to_string(file)?;
        source.push_str("    (");
        source.push_str(&format!("{relative:?}"));
        source.push_str(", ");
        source.push_str(&format!("{contents:?}"));
        source.push_str("),\n");
    }
    source.push_str("];\n");
    Ok(source)
}

fn collect_rust_files(directory: &Path, files: &mut Vec<PathBuf>) -> io::Result<()> {
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let file_type = entry.file_type()?;
        if file_type.is_symlink() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!(
                    "test source manifest rejects symlink entry: {}",
                    entry.path().display()
                ),
            ));
        }
        if file_type.is_dir() {
            collect_rust_files(&entry.path(), files)?;
        } else if file_type.is_file()
            && entry
                .path()
                .extension()
                .is_some_and(|extension| extension == "rs")
        {
            files.push(entry.path());
        }
    }
    Ok(())
}

fn normalized_relative_path(root: &Path, file: &Path) -> io::Result<String> {
    let relative = file.strip_prefix(root).map_err(io::Error::other)?;
    let mut components = Vec::new();
    for component in relative.components() {
        if let Component::Normal(component) = component {
            components.push(component.to_string_lossy());
        }
    }
    Ok(components.join("/"))
}
