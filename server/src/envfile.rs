/// Parse dotenv entries in source order, preserving duplicate keys.
pub fn parse_dotenv(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                return None;
            }
            let (key, value) = line.split_once('=')?;
            let key = key.trim();
            if key.is_empty() {
                return None;
            }
            let value = value.trim().trim_matches('"').trim_matches('\'');
            Some((key.to_owned(), value.to_owned()))
        })
        .collect()
}

/// Prefer a nonempty environment secret over nonempty file contents.
pub fn pick_session_secret(env_value: Option<&str>, file_contents: Option<&str>) -> Option<String> {
    env_value
        .into_iter()
        .chain(file_contents)
        .map(str::trim)
        .find(|value| !value.is_empty())
        .map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::{parse_dotenv, pick_session_secret};

    #[test]
    fn dotenv_skips_comments_blank_lines_and_invalid_entries() {
        assert!(parse_dotenv("\n  \n # comment\nno equals\n = value\n").is_empty());
    }

    #[test]
    fn dotenv_trims_entries_and_preserves_equals() {
        assert_eq!(
            parse_dotenv("  KEY  =  value=with=equals  "),
            vec![("KEY".into(), "value=with=equals".into())]
        );
    }

    #[test]
    fn dotenv_strips_quotes_using_existing_trim_rules() {
        assert_eq!(
            parse_dotenv(
                "DOUBLE=\"value\"\nSINGLE='value'\nREPEATED=\"\"'value'\"\"\nSPACE=\" value \""
            ),
            vec![
                ("DOUBLE".into(), "value".into()),
                ("SINGLE".into(), "value".into()),
                ("REPEATED".into(), "value".into()),
                ("SPACE".into(), " value ".into()),
            ]
        );
    }

    #[test]
    fn dotenv_preserves_order_duplicates_and_empty_values() {
        assert_eq!(
            parse_dotenv("KEY=first\nKEY=second\nEMPTY="),
            vec![
                ("KEY".into(), "first".into()),
                ("KEY".into(), "second".into()),
                ("EMPTY".into(), "".into()),
            ]
        );
    }

    #[test]
    fn session_secret_prefers_nonempty_env_then_file() {
        for (env, file, expected) in [
            (Some(" env \n"), Some("file"), Some("env")),
            (Some(" \t\n"), Some(" file \n"), Some("file")),
            (None, Some("file"), Some("file")),
            (None, Some(" \t\n"), None),
            (Some(""), Some(""), None),
            (None, None, None),
        ] {
            assert_eq!(pick_session_secret(env, file).as_deref(), expected);
        }
    }
}
