use std::fmt::Write as _;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus};

use thiserror::Error;

use crate::cli::SetupArgs;

const RIGHT_STATUS_LUA: &str = include_str!("../contrib/wezterm/right-status.lua");
const HERDR_PLUGIN_TOML: &str = include_str!("../contrib/herdr-plugin/herdr-plugin.toml");
const HERDR_PLUGIN_UPDATE_STATUS: &str = include_str!("../contrib/herdr-plugin/update-status");

const SETUP_BEGIN: &str = "-- wezterm-git-status-bridge setup begin";
const SETUP_END: &str = "-- wezterm-git-status-bridge setup end";
const SHELL_BEGIN: &str = "# wezterm-git-status-bridge setup begin";
const SHELL_END: &str = "# wezterm-git-status-bridge setup end";

#[derive(Debug, Error)]
pub enum SetupError {
    #[error("HOME is not set")]
    MissingHome,
    #[error("failed to resolve current executable: {0}")]
    CurrentExe(io::Error),
    #[error("failed to create {path}: {source}")]
    CreateDir { path: PathBuf, source: io::Error },
    #[error("failed to read {path}: {source}")]
    Read { path: PathBuf, source: io::Error },
    #[error("failed to write {path}: {source}")]
    Write { path: PathBuf, source: io::Error },
    #[error("failed to mark {path} executable: {source}")]
    Permissions { path: PathBuf, source: io::Error },
    #[error("failed to link Herdr plugin: {0}")]
    HerdrLink(#[source] io::Error),
    #[error("herdr plugin link failed with status {0}")]
    HerdrLinkStatus(ExitStatus),
}

pub fn run(args: &SetupArgs) -> Result<(), SetupError> {
    let home = home_dir()?;
    let wezterm_file = args
        .wezterm_config_file
        .clone()
        .unwrap_or_else(|| default_wezterm_dir(&home, args).join("wezterm.lua"));
    let wezterm_dir = args
        .wezterm_config_dir
        .clone()
        .or_else(|| config_parent(&wezterm_file))
        .unwrap_or_else(|| home.join(".config/wezterm"));
    let binary_path = std::env::current_exe().map_err(SetupError::CurrentExe)?;
    let shell_hook = args.shell_hook || (args.herdr && !args.no_shell_hook);

    create_dir(&wezterm_dir)?;
    write_file(&wezterm_dir.join("right-status.lua"), RIGHT_STATUS_LUA)?;

    if args.herdr {
        let plugin_dir = wezterm_dir.join("herdr-plugin");
        write_herdr_plugin(&plugin_dir)?;
        let herdr_bin = args
            .herdr_bin
            .as_deref()
            .unwrap_or_else(|| Path::new("herdr"));
        link_herdr_plugin(herdr_bin, &plugin_dir)?;
    }

    if shell_hook {
        let zshrc = args.zshrc.clone().unwrap_or_else(|| home.join(".zshrc"));
        upsert_zsh_hook(&zshrc, &binary_path)?;
    }

    upsert_wezterm_config(&wezterm_file, args.herdr, &binary_path)?;

    Ok(())
}

fn default_wezterm_dir(home: &Path, args: &SetupArgs) -> PathBuf {
    args.wezterm_config_dir
        .clone()
        .unwrap_or_else(|| home.join(".config/wezterm"))
}

fn config_parent(path: &Path) -> Option<PathBuf> {
    path.parent().map(|parent| {
        if parent.as_os_str().is_empty() {
            PathBuf::from(".")
        } else {
            parent.to_path_buf()
        }
    })
}

fn home_dir() -> Result<PathBuf, SetupError> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|path| !path.as_os_str().is_empty())
        .ok_or(SetupError::MissingHome)
}

fn create_dir(path: &Path) -> Result<(), SetupError> {
    fs::create_dir_all(path).map_err(|source| SetupError::CreateDir {
        path: path.to_path_buf(),
        source,
    })
}

fn read_optional(path: &Path) -> Result<Option<String>, SetupError> {
    match fs::read_to_string(path) {
        Ok(value) => Ok(Some(value)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(source) => Err(SetupError::Read {
            path: path.to_path_buf(),
            source,
        }),
    }
}

fn write_file(path: &Path, value: &str) -> Result<(), SetupError> {
    if let Some(parent) = path.parent() {
        create_dir(parent)?;
    }
    fs::write(path, value).map_err(|source| SetupError::Write {
        path: path.to_path_buf(),
        source,
    })
}

fn upsert_wezterm_config(path: &Path, herdr: bool, binary_path: &Path) -> Result<(), SetupError> {
    let current = read_optional(path)?;
    let block = current
        .as_deref()
        .and_then(existing_marked_lua_block)
        .and_then(preserved_setup_options)
        .map_or_else(
            || wezterm_block(herdr, binary_path),
            |options| wezterm_block_with_options(herdr, binary_path, &options),
        );
    let next = match current {
        Some(current) => upsert_lua_block(&current, &block),
        None => new_wezterm_config(&block),
    };
    write_file(path, &next)
}

fn wezterm_block(herdr: bool, binary_path: &Path) -> String {
    wezterm_block_with_options(herdr, binary_path, &[])
}

fn wezterm_block_with_options(
    herdr: bool,
    binary_path: &Path,
    preserved_options: &[String],
) -> String {
    let escaped_binary = lua_string(binary_path);
    let mut block = String::new();
    block.push_str(SETUP_BEGIN);
    block.push_str("\nlocal git_status = require(\"right-status\")\ngit_status.setup({\n");
    if herdr {
        block.push_str("  auto_update = false,\n");
    }
    let _ = writeln!(block, "  binary_path = {escaped_binary},");
    for option in preserved_options {
        block.push_str(option);
        block.push('\n');
    }
    block.push_str("})\n");
    block.push_str(SETUP_END);
    block
}

fn lua_string(path: &Path) -> String {
    format!(
        "\"{}\"",
        path.to_string_lossy()
            .replace('\\', "\\\\")
            .replace('"', "\\\"")
    )
}

fn new_wezterm_config(block: &str) -> String {
    format!(
        "local wezterm = require(\"wezterm\")\nlocal config = wezterm.config_builder()\n\n{block}\n\nreturn config\n"
    )
}

fn upsert_lua_block(current: &str, block: &str) -> String {
    if let Some(next) = replace_marked_block(current, SETUP_BEGIN, SETUP_END, block) {
        return next;
    }

    let mut lines = current.lines().collect::<Vec<_>>();
    let insert_at = lines
        .iter()
        .rposition(|line| line.trim_start().starts_with("return "))
        .unwrap_or(lines.len());
    lines.insert(insert_at, block);
    let mut next = lines.join("\n");
    next.push('\n');
    next
}

fn existing_marked_lua_block(current: &str) -> Option<&str> {
    marked_block(current, SETUP_BEGIN, SETUP_END)
}

fn marked_block<'a>(current: &'a str, begin: &str, end: &str) -> Option<&'a str> {
    let start = current.find(begin)?;
    let end_start = current[start..].find(end)? + start;
    let end_index = end_start + end.len();
    Some(&current[start..end_index])
}

fn preserved_setup_options(block: &str) -> Option<Vec<String>> {
    let lines = block.lines().collect::<Vec<_>>();
    let start = lines
        .iter()
        .position(|line| line.contains("git_status.setup({"))?;
    let end = setup_table_end(&lines, start)?;

    let mut preserved = Vec::new();
    let mut nesting = LuaNesting::setup_table();
    for line in &lines[start + 1..end] {
        if nesting.is_setup_table_top_level() && is_managed_setup_option(line) {
            continue;
        }
        preserved.push((*line).to_owned());
        nesting.update(line);
    }

    trim_blank_edges(&mut preserved);
    Some(preserved)
}

fn setup_table_end(lines: &[&str], setup_start: usize) -> Option<usize> {
    let mut nesting = LuaNesting::setup_table();
    for (index, line) in lines.iter().enumerate().skip(setup_start + 1) {
        nesting.update(line);
        if nesting.is_setup_table_closed() {
            return Some(index);
        }
    }
    None
}

fn is_managed_setup_option(line: &str) -> bool {
    matches!(
        top_level_option_key(line),
        Some("auto_update" | "binary_path")
    )
}

fn top_level_option_key(line: &str) -> Option<&str> {
    let trimmed = line.trim_start();
    let mut end = 0;
    for (index, character) in trimmed.char_indices() {
        if index == 0 {
            if !(character == '_' || character.is_ascii_alphabetic()) {
                return None;
            }
        } else if !(character == '_' || character.is_ascii_alphanumeric()) {
            break;
        }
        end = index + character.len_utf8();
    }
    if end == 0 {
        return None;
    }
    trimmed[end..]
        .trim_start()
        .starts_with('=')
        .then_some(&trimmed[..end])
}

#[derive(Default)]
struct LuaNesting {
    table_depth: usize,
    function_depth: usize,
    long_bracket_equals: Option<usize>,
}

impl LuaNesting {
    fn setup_table() -> Self {
        Self {
            table_depth: 1,
            ..Self::default()
        }
    }

    fn is_setup_table_top_level(&self) -> bool {
        self.table_depth == 1 && self.function_depth == 0 && self.long_bracket_equals.is_none()
    }

    fn is_setup_table_closed(&self) -> bool {
        self.table_depth == 0 && self.function_depth == 0 && self.long_bracket_equals.is_none()
    }

    fn update(&mut self, line: &str) {
        let code = lua_code_for_nesting(line, &mut self.long_bracket_equals);
        self.table_depth = self
            .table_depth
            .saturating_add(code.chars().filter(|character| *character == '{').count())
            .saturating_sub(code.chars().filter(|character| *character == '}').count());

        self.function_depth = self
            .function_depth
            .saturating_add(count_lua_word(&code, "function"))
            .saturating_sub(count_lua_word(&code, "end"));
    }
}

fn lua_code_for_nesting(line: &str, long_bracket_equals: &mut Option<usize>) -> String {
    let bytes = line.as_bytes();
    let mut code = String::with_capacity(line.len());
    let mut index = 0;
    while index < bytes.len() {
        if let Some(equals) = *long_bracket_equals {
            if let Some(close_end) = long_bracket_close_end(bytes, index, equals) {
                *long_bracket_equals = None;
                index = close_end;
            } else {
                index += 1;
            }
            continue;
        }

        if bytes[index] == b'-' && bytes.get(index + 1) == Some(&b'-') {
            if let Some((equals, open_end)) = long_bracket_open_end(bytes, index + 2) {
                *long_bracket_equals = Some(equals);
                index = open_end;
                continue;
            }
            break;
        }

        if bytes[index] == b'\'' || bytes[index] == b'"' {
            index = short_string_end(bytes, index + 1, bytes[index]);
            code.push(' ');
            continue;
        }

        if let Some((equals, open_end)) = long_bracket_open_end(bytes, index) {
            *long_bracket_equals = Some(equals);
            index = open_end;
            code.push(' ');
            continue;
        }

        let character = line[index..]
            .chars()
            .next()
            .expect("index is within string bounds");
        code.push(character);
        index += character.len_utf8();
    }
    code
}

fn long_bracket_open_end(bytes: &[u8], index: usize) -> Option<(usize, usize)> {
    if bytes.get(index) != Some(&b'[') {
        return None;
    }
    let mut cursor = index + 1;
    while bytes.get(cursor) == Some(&b'=') {
        cursor += 1;
    }
    (bytes.get(cursor) == Some(&b'[')).then_some((cursor - index - 1, cursor + 1))
}

fn long_bracket_close_end(bytes: &[u8], index: usize, equals: usize) -> Option<usize> {
    if bytes.get(index) != Some(&b']') {
        return None;
    }
    let mut cursor = index + 1;
    for _ in 0..equals {
        if bytes.get(cursor) != Some(&b'=') {
            return None;
        }
        cursor += 1;
    }
    (bytes.get(cursor) == Some(&b']')).then_some(cursor + 1)
}

fn short_string_end(bytes: &[u8], mut index: usize, quote: u8) -> usize {
    while index < bytes.len() {
        match bytes[index] {
            b'\\' => index = index.saturating_add(2),
            value if value == quote => return index + 1,
            _ => index += 1,
        }
    }
    bytes.len()
}

fn count_lua_word(value: &str, word: &str) -> usize {
    value
        .split(|character: char| !(character == '_' || character.is_ascii_alphanumeric()))
        .filter(|part| *part == word)
        .count()
}

fn trim_blank_edges(lines: &mut Vec<String>) {
    while lines.first().is_some_and(|line| line.trim().is_empty()) {
        lines.remove(0);
    }
    while lines.last().is_some_and(|line| line.trim().is_empty()) {
        lines.pop();
    }
}

fn replace_marked_block(current: &str, begin: &str, end: &str, block: &str) -> Option<String> {
    let start = current.find(begin)?;
    let end_start = current[start..].find(end)? + start;
    let end_index = end_start + end.len();
    let mut next = String::new();
    next.push_str(current[..start].trim_end_matches('\n'));
    if !next.is_empty() {
        next.push('\n');
    }
    next.push_str(block);
    let tail = current[end_index..].trim_start_matches('\n');
    if !tail.is_empty() {
        next.push('\n');
        next.push_str(tail);
    }
    if !next.ends_with('\n') {
        next.push('\n');
    }
    Some(next)
}

fn write_herdr_plugin(path: &Path) -> Result<(), SetupError> {
    create_dir(path)?;
    write_file(&path.join("herdr-plugin.toml"), HERDR_PLUGIN_TOML)?;
    let script = path.join("update-status");
    write_file(&script, HERDR_PLUGIN_UPDATE_STATUS)?;
    set_executable(&script)
}

#[cfg(unix)]
fn set_executable(path: &Path) -> Result<(), SetupError> {
    use std::os::unix::fs::PermissionsExt as _;

    let mut permissions = fs::metadata(path)
        .map_err(|source| SetupError::Permissions {
            path: path.to_path_buf(),
            source,
        })?
        .permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).map_err(|source| SetupError::Permissions {
        path: path.to_path_buf(),
        source,
    })
}

#[cfg(not(unix))]
fn set_executable(_path: &Path) -> Result<(), SetupError> {
    Ok(())
}

fn link_herdr_plugin(herdr_bin: &Path, path: &Path) -> Result<(), SetupError> {
    let status = Command::new(herdr_bin)
        .args(["plugin", "link"])
        .arg(path)
        .status()
        .map_err(SetupError::HerdrLink)?;
    if status.success() {
        Ok(())
    } else {
        Err(SetupError::HerdrLinkStatus(status))
    }
}

fn upsert_zsh_hook(path: &Path, binary_path: &Path) -> Result<(), SetupError> {
    let block = zsh_hook_block(binary_path);
    let next = if let Some(current) = read_optional(path)? {
        replace_marked_block(&current, SHELL_BEGIN, SHELL_END, &block)
            .unwrap_or_else(|| append_block(&current, &block))
    } else {
        let mut value = block;
        value.push('\n');
        value
    };
    write_file(path, &next)
}

fn zsh_hook_block(binary_path: &Path) -> String {
    let binary = shell_single_quote(&binary_path.to_string_lossy());
    format!(
        "{SHELL_BEGIN}\n_wezterm_git_status_bridge_update() {{\n  {binary} update --pane-id \"${{WEZTERM_PANE:-shell}}\" --cwd \"$PWD\" >/dev/null 2>&1 &!\n}}\nautoload -Uz add-zsh-hook\nadd-zsh-hook chpwd _wezterm_git_status_bridge_update\nadd-zsh-hook precmd _wezterm_git_status_bridge_update\n{SHELL_END}"
    )
}

fn shell_single_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

fn append_block(current: &str, block: &str) -> String {
    let mut next = current.trim_end_matches('\n').to_owned();
    if !next.is_empty() {
        next.push_str("\n\n");
    }
    next.push_str(block);
    next.push('\n');
    next
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use tempfile::TempDir;

    use crate::cli::SetupArgs;

    use super::{SETUP_BEGIN, SETUP_END, SHELL_BEGIN, append_block, upsert_lua_block};

    #[test]
    fn inserts_lua_block_before_return() {
        let updated = upsert_lua_block("local config = {}\nreturn config\n", "BLOCK");

        assert_eq!(updated, "local config = {}\nBLOCK\nreturn config\n");
    }

    #[test]
    fn replaces_existing_lua_block() {
        let updated = upsert_lua_block(
            "local config = {}\n-- wezterm-git-status-bridge setup begin\nOLD\n-- wezterm-git-status-bridge setup end\nreturn config\n",
            "NEW",
        );

        assert_eq!(updated, "local config = {}\nNEW\nreturn config\n");
    }

    #[test]
    fn appends_shell_block_with_spacing() {
        let updated = append_block("export PATH=$HOME/bin\n", "BLOCK");

        assert_eq!(updated, "export PATH=$HOME/bin\n\nBLOCK\n");
    }

    #[test]
    fn markers_do_not_overlap() {
        assert_ne!(SETUP_BEGIN, SHELL_BEGIN);
        assert!(SETUP_END.contains("setup end"));
    }

    #[test]
    fn setup_writes_wezterm_files() {
        let temp = TempDir::new().expect("create temp dir");
        let config_dir = temp.path().join("wezterm");
        let config_file = config_dir.join("wezterm.lua");

        super::run(&SetupArgs {
            wezterm_config_dir: Some(config_dir.clone()),
            wezterm_config_file: Some(config_file.clone()),
            ..SetupArgs::default()
        })
        .expect("run setup");

        assert!(config_dir.join("right-status.lua").is_file());
        let config = std::fs::read_to_string(config_file).expect("read config");
        assert!(config.contains("git_status.setup({"));
        assert!(config.contains("return config"));
    }

    #[test]
    fn setup_shell_hook_updates_zshrc() {
        let temp = TempDir::new().expect("create temp dir");
        let zshrc = temp.path().join(".zshrc");

        super::run(&SetupArgs {
            wezterm_config_dir: Some(temp.path().join("wezterm")),
            shell_hook: true,
            zshrc: Some(zshrc.clone()),
            ..SetupArgs::default()
        })
        .expect("run setup");

        let content = std::fs::read_to_string(zshrc).expect("read zshrc");
        assert!(content.contains("add-zsh-hook chpwd"));
        assert!(content.contains("add-zsh-hook precmd"));
        assert!(content.contains("--cwd \"$PWD\""));
        assert!(!content.contains("pane list"));
        assert!(!content.contains("--event-json"));
    }

    #[test]
    fn setup_config_file_places_lua_next_to_config() {
        let temp = TempDir::new().expect("create temp dir");
        let custom_dir = temp.path().join("custom");
        let config_file = custom_dir.join("wezterm.lua");

        super::run(&SetupArgs {
            wezterm_config_file: Some(config_file),
            ..SetupArgs::default()
        })
        .expect("run setup");

        assert!(custom_dir.join("right-status.lua").is_file());
        assert!(
            !temp
                .path()
                .join(".config/wezterm/right-status.lua")
                .is_file()
        );
    }

    #[test]
    fn setup_preserves_custom_lua_options() {
        let temp = TempDir::new().expect("create temp dir");
        let config_dir = temp.path().join("wezterm");
        let config_file = config_dir.join("wezterm.lua");
        let herdr = temp.path().join("herdr");
        write_script(&herdr, "exit 0\n");

        std::fs::create_dir_all(&config_dir).expect("create config dir");
        std::fs::write(
            &config_file,
            r##"local config = {}
-- wezterm-git-status-bridge setup begin
local git_status = require("right-status")
git_status.setup({
  auto_update = true,
  binary_path = "/old/bin/wezterm-git-status-bridge",
  separator = "}",
  time_format = "function %H end",
  -- }) function end
  on_reload = function(window, pane)
    window:set_config_overrides({
      colors = {
        tab_bar = { background = "#1f2335" },
      },
    })
    window:set_right_status("mode")
  end,
  mode_styles = {
    resize = { label = "RESIZE", bg = "#7aa2f7", fg = "#1f2335" },
  },
})
-- wezterm-git-status-bridge setup end
return config
"##,
        )
        .expect("write config");

        super::run(&SetupArgs {
            wezterm_config_dir: Some(config_dir),
            wezterm_config_file: Some(config_file.clone()),
            herdr: true,
            herdr_bin: Some(herdr),
            no_shell_hook: true,
            ..SetupArgs::default()
        })
        .expect("run setup");

        let config = std::fs::read_to_string(config_file).expect("read config");
        assert!(config.contains("auto_update = false"));
        assert!(config.contains("separator = \"}\""));
        assert!(config.contains("time_format = \"function %H end\""));
        assert!(config.contains("window:set_config_overrides({"));
        assert!(config.contains("tab_bar = { background = \"#1f2335\""));
        assert!(config.contains("mode_styles = {"));
        assert!(config.contains("resize = { label = \"RESIZE\""));
        assert!(config.contains("on_reload = function(window, pane)"));
        assert!(config.contains("window:set_right_status(\"mode\")"));
        assert!(!config.contains("/old/bin/wezterm-git-status-bridge"));
    }

    #[test]
    fn setup_herdr_link_failure_does_not_switch_wezterm_config() {
        let temp = TempDir::new().expect("create temp dir");
        let config_dir = temp.path().join("wezterm");
        let config_file = config_dir.join("wezterm.lua");
        let zshrc = temp.path().join(".zshrc");
        let herdr = temp.path().join("herdr");
        write_script(&herdr, "exit 7\n");

        std::fs::create_dir_all(&config_dir).expect("create config dir");
        std::fs::write(&config_file, "return {}\n").expect("write config");

        let error = super::run(&SetupArgs {
            wezterm_config_dir: Some(config_dir),
            wezterm_config_file: Some(config_file.clone()),
            herdr: true,
            herdr_bin: Some(herdr),
            zshrc: Some(zshrc.clone()),
            ..SetupArgs::default()
        })
        .expect_err("setup should fail");

        assert!(matches!(error, super::SetupError::HerdrLinkStatus(_)));
        assert_eq!(
            std::fs::read_to_string(config_file).expect("read config"),
            "return {}\n"
        );
        assert!(!zshrc.exists());
    }

    #[cfg(unix)]
    fn write_script(path: &Path, body: &str) {
        use std::os::unix::fs::PermissionsExt as _;

        std::fs::write(path, format!("#!/bin/sh\n{body}")).expect("write script");
        let mut permissions = std::fs::metadata(path)
            .expect("script metadata")
            .permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(path, permissions).expect("make script executable");
    }

    #[cfg(not(unix))]
    fn write_script(path: &Path, body: &str) {
        std::fs::write(path, body).expect("write script");
    }
}
