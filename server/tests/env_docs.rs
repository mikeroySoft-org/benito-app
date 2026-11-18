use std::{collections::BTreeSet, fs, path::Path};

fn collect_env_names(dir: &Path, names: &mut BTreeSet<String>) {
    for entry in fs::read_dir(dir).expect("read source directory") {
        let path = entry.expect("read source entry").path();
        if path.is_dir() {
            collect_env_names(&path, names);
        } else if path.extension().is_some_and(|ext| ext == "rs") {
            let source = fs::read_to_string(&path).expect("read Rust source");
            for suffix in source.split("env::var").skip(1) {
                let suffix = suffix.strip_prefix("_os").unwrap_or(suffix).trim_start();
                let Some(argument) = suffix.strip_prefix('(') else {
                    continue;
                };
                let Some(literal) = argument.trim_start().strip_prefix('"') else {
                    continue;
                };
                if let Some((name, rest)) = literal.split_once('"') {
                    if rest.trim_start().starts_with(')') {
                        names.insert(name.to_owned());
                    }
                }
            }
        }
    }
}

#[test]
fn every_literal_env_read_is_documented() {
    let server = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut names = BTreeSet::new();
    collect_env_names(&server.join("src"), &mut names);
    assert!(!names.is_empty(), "env scanner found no names");
    for required in ["SESSION_SECRET", "BIND_ADDR", "DATABASE_PATH"] {
        assert!(names.contains(required), "env scanner missed {required}");
    }

    let mut missing = Vec::new();
    for file in ["README.md", "../.env.example"] {
        let text = fs::read_to_string(server.join(file)).expect("read configuration documentation");
        let documented: BTreeSet<_> = text
            .split(|c: char| !c.is_ascii_alphanumeric() && c != '_')
            .collect();
        for name in &names {
            if !documented.contains(name.as_str()) {
                missing.push(format!("({name}, {file})"));
            }
        }
    }
    assert!(
        missing.is_empty(),
        "Undocumented environment variables:\n{}",
        missing.join("\n")
    );
}
