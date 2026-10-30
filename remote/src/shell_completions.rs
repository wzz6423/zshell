use crate::protocol::{invalid, new_id};
use std::collections::BTreeMap;
use std::fs::{self, DirBuilder, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

include!(concat!(env!("OUT_DIR"), "/completions.rs"));

pub struct Integration(PathBuf);

impl Integration {
    pub fn prepare(state: &Path, environment: &mut BTreeMap<String, String>) -> io::Result<Option<Self>> {
        let shell = crate::pty::login_shell();
        if Path::new(&shell).file_name().and_then(|name| name.to_str()) != Some("zsh") {
            return Ok(None);
        }
        let original = environment.get("ZDOTDIR").cloned()
            .or_else(|| std::env::var("ZDOTDIR").ok())
            .or_else(|| environment.get("HOME").cloned())
            .or_else(|| std::env::var("HOME").ok())
            .ok_or_else(|| invalid("Remote shell configuration directory is unavailable"))?;
        let path = state.join(format!("shell-completions-{}", new_id()?));
        DirBuilder::new().mode(0o700).create(&path)?;
        let integration = Self(path);
        DirBuilder::new().mode(0o700).create(integration.0.join("completions"))?;
        for (name, text) in FILES { integration.write(name, text)?; }
        for name in [".zshenv", ".zprofile", ".zlogin"] {
            integration.write(name, &format!(
                "[[ -r \"$ZSHELL_ORIGINAL_ZDOTDIR/{name}\" ]] && source \"$ZSHELL_ORIGINAL_ZDOTDIR/{name}\"\n"
            ))?;
        }
        integration.write(".zshrc", &format!(
            "fpath+=({})\n\
             [[ \"$HISTFILE\" == \"$ZDOTDIR\"/* ]] && HISTFILE=\"$ZSHELL_ORIGINAL_ZDOTDIR/.zsh_history\"\n\
             export ZDOTDIR=\"$ZSHELL_ORIGINAL_ZDOTDIR\"\n\
             [[ -r \"$ZDOTDIR/.zshrc\" ]] && source \"$ZDOTDIR/.zshrc\"\nsource {}\n",
            quote(&integration.0.join("completions")), quote(&integration.0.join("init.zsh"))
        ))?;
        environment.insert("ZSHELL_ORIGINAL_ZDOTDIR".into(), original);
        environment.insert("ZDOTDIR".into(), integration.0.to_string_lossy().into_owned());
        Ok(Some(integration))
    }

    fn write(&self, name: &str, text: &str) -> io::Result<()> {
        OpenOptions::new().write(true).create_new(true).mode(0o600)
            .open(self.0.join(name))?.write_all(text.as_bytes())
    }
}

impl Drop for Integration {
    fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); }
}

fn quote(path: &Path) -> String {
    format!("'{}'", path.to_string_lossy().replace('\'', "'\\''"))
}
