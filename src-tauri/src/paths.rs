//! Windows extended-length path normalization.
//!
//! Rust's [`std::fs::canonicalize`] returns `\\?\C:\...` (or `\\?\UNC\...`) on Windows. The
//! prefix is valid for ordinary file I/O, but it leaks into child processes and config files
//! where Python 3.12's venv/ensurepip and pip's entry-point writer intermittently fail
//! (see `_normal_runtime_path` in `python/worker_bootstrap.py`, which had to duplicate this
//! cleanup on the Python side five separate times).
//!
//! Every path that leaves the Rust process — into an env var, a JSON record, or a child
//! process argument — must go through [`normalize_win32_path`]. The Python-side defense layers
//! remain as backstop for states persisted by older app versions.

use std::path::{Path, PathBuf};

/// Strip the Windows extended-length prefix (`\\?\C:\...`, `\\?\UNC\...`) from a path.
///
/// A no-op on non-Windows targets and for paths that never carried the prefix. Extended
/// paths are only meaningful above the classic 260-char `MAX_PATH` limit; they are kept
/// intact here so unusually long installs still retain long-path support.
pub fn normalize_win32_path(path: &Path) -> PathBuf {
    #[cfg(windows)]
    {
        let text = path.to_string_lossy();
        if let Some(unc) = text.strip_prefix(r"\\?\UNC\") {
            return PathBuf::from(format!(r"\\{unc}"));
        }
        if let Some(rest) = text.strip_prefix(r"\\?\") {
            return PathBuf::from(rest);
        }
        path.to_path_buf()
    }
    #[cfg(not(windows))]
    {
        let _ = path;
        path.to_path_buf()
    }
}

/// Normalize and format a path for handoff to Python, JSON, or a child process.
pub fn display_normalized(path: &Path) -> String {
    normalize_win32_path(path).to_string_lossy().to_string()
}

/// Normalize a path for the current target and return it as an owned [`PathBuf`].
pub fn normalized(path: &Path) -> PathBuf {
    normalize_win32_path(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_extended_prefix_on_windows() {
        #[cfg(windows)]
        {
            assert_eq!(
                normalize_win32_path(Path::new(r"\\?\C:\Users\test\runtime-envs")),
                PathBuf::from(r"C:\Users\test\runtime-envs")
            );
            assert_eq!(
                normalize_win32_path(Path::new(r"\\?\UNC\server\share\runtime")),
                PathBuf::from(r"\\server\share\runtime")
            );
        }
        #[cfg(not(windows))]
        {
            let path = Path::new(r"\\?\C:\Users\test");
            assert_eq!(normalize_win32_path(path), path.to_path_buf());
        }
    }

    #[test]
    fn keeps_ordinary_paths_intact() {
        let path = Path::new("C:\\Users\\test\\runtime-envs");
        assert_eq!(normalize_win32_path(path), path.to_path_buf());
    }

    #[test]
    fn display_normalized_returns_lossy_string() {
        assert_eq!(
            display_normalized(Path::new("C:\\temp")),
            "C:\\temp".to_string()
        );
    }
}
