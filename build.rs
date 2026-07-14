use std::{env, fs, path::PathBuf};

fn main() {
    let manifest_dir = env::var_os("CARGO_MANIFEST_DIR")
        .map(PathBuf::from)
        .expect("Cargo must set CARGO_MANIFEST_DIR");
    let version_path = manifest_dir.join("VERSION");

    println!("cargo:rerun-if-changed={}", version_path.display());

    let version = fs::read_to_string(&version_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", version_path.display()));
    let version = version.trim_end_matches(&['\r', '\n'][..]);

    assert!(
        is_valid_tag_version(version),
        "invalid VERSION value `{version}`; expected a git tag style version such as v1.0.0"
    );

    let engine_version = version
        .strip_prefix('v')
        .expect("validated VERSION values always start with v");
    println!("cargo:rustc-env=KBASE_LANCE_ENGINE_VERSION={engine_version}");
}

fn is_valid_tag_version(version: &str) -> bool {
    let Some(version) = version.strip_prefix('v') else {
        return false;
    };

    let mut components = version.splitn(3, '.');
    let (Some(major), Some(minor), Some(patch_and_suffix)) =
        (components.next(), components.next(), components.next())
    else {
        return false;
    };

    if !is_numeric_identifier(major) || !is_numeric_identifier(minor) {
        return false;
    }

    let suffix_start = patch_and_suffix.find(['-', '.']);
    let (patch, suffix) = match suffix_start {
        Some(index) => patch_and_suffix.split_at(index),
        None => (patch_and_suffix, ""),
    };

    is_numeric_identifier(patch)
        && (suffix.is_empty()
            || (suffix.len() > 1
                && suffix
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.'))))
}

fn is_numeric_identifier(value: &str) -> bool {
    !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit())
}
