use std::{env, fs, path::PathBuf};

fn main() {
    let resources = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap())
        .join("../mac/zshell/ShellIntegration/TerminalCompletions")
        .canonicalize().unwrap();
    println!("cargo:rerun-if-changed={}", resources.display());
    let mut files: Vec<_> = fs::read_dir(resources.join("completions")).unwrap()
        .map(|entry| entry.unwrap().path()).collect();
    files.extend(["init.zsh", "zsh-autosuggestions.zsh", "LICENSE-zsh-autosuggestions.txt",
        "LICENSE-zsh-completions.txt", "SOURCES.txt"].map(|name| resources.join(name)));
    files.sort();
    let source = "const FILES: &[(&str, &str)] = &[\n".to_owned()
        + &files.iter().map(|path| format!("({:?}, include_str!({:?})),\n",
            path.strip_prefix(&resources).unwrap().to_str().unwrap(), path.to_str().unwrap()))
            .collect::<String>() + "];\n";
    fs::write(PathBuf::from(env::var("OUT_DIR").unwrap()).join("completions.rs"), source).unwrap();
}
