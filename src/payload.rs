use std::fmt;
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Payload {
    pub at: u64,
    pub pane_id: String,
    pub cwd: PathBuf,
    pub repository: Option<RepositoryStatus>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RepositoryStatus {
    pub repo: String,
    pub ref_name: String,
    pub flags: StatusFlags,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct StatusFlags {
    bits: u8,
}

impl StatusFlags {
    const DETACHED: u8 = 1 << 0;
    const DIRTY: u8 = 1 << 1;
    const WORKTREE: u8 = 1 << 2;
    const REBASE: u8 = 1 << 3;
    const CHERRY_PICK: u8 = 1 << 4;

    pub fn set_detached(&mut self, enabled: bool) {
        self.set(Self::DETACHED, enabled);
    }

    pub fn set_dirty(&mut self, enabled: bool) {
        self.set(Self::DIRTY, enabled);
    }

    pub fn set_worktree(&mut self, enabled: bool) {
        self.set(Self::WORKTREE, enabled);
    }

    pub fn set_rebase(&mut self, enabled: bool) {
        self.set(Self::REBASE, enabled);
    }

    pub fn set_cherry_pick(&mut self, enabled: bool) {
        self.set(Self::CHERRY_PICK, enabled);
    }

    pub fn detached(self) -> bool {
        self.contains(Self::DETACHED)
    }

    pub fn dirty(self) -> bool {
        self.contains(Self::DIRTY)
    }

    pub fn worktree(self) -> bool {
        self.contains(Self::WORKTREE)
    }

    pub fn rebase(self) -> bool {
        self.contains(Self::REBASE)
    }

    pub fn cherry_pick(self) -> bool {
        self.contains(Self::CHERRY_PICK)
    }

    fn set(&mut self, flag: u8, enabled: bool) {
        if enabled {
            self.bits |= flag;
        } else {
            self.bits &= !flag;
        }
    }

    fn contains(self, flag: u8) -> bool {
        self.bits & flag != 0
    }
}

impl Payload {
    pub fn encode_line(&self) -> String {
        let (present, repo, ref_name, flags) = match &self.repository {
            Some(status) => (
                "1",
                status.repo.as_str(),
                status.ref_name.as_str(),
                status.flags.to_string(),
            ),
            None => ("0", "", "", String::new()),
        };

        format!(
            "herdrgit1\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n",
            self.at,
            self.pane_id,
            self.cwd.display(),
            present,
            repo,
            ref_name,
            flags
        )
    }
}

impl fmt::Display for StatusFlags {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.detached() {
            formatter.write_str("D")?;
        }
        if self.dirty() {
            formatter.write_str("d")?;
        }
        if self.worktree() {
            formatter.write_str("w")?;
        }
        if self.rebase() {
            formatter.write_str("R")?;
        }
        if self.cherry_pick() {
            formatter.write_str("C")?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{Payload, RepositoryStatus, StatusFlags};

    #[test]
    fn encodes_missing_repository_as_absent_status() {
        let payload = Payload {
            at: 123,
            pane_id: "w1:p1".to_owned(),
            cwd: "/tmp/project".into(),
            repository: None,
        };

        assert_eq!(
            payload.encode_line(),
            "herdrgit1\t123\tw1:p1\t/tmp/project\t0\t\t\t\n"
        );
    }

    #[test]
    fn encodes_repository_status_with_compact_flags() {
        let mut flags = StatusFlags::default();
        flags.set_dirty(true);
        flags.set_worktree(true);

        let payload = Payload {
            at: 123,
            pane_id: "w1:p1".to_owned(),
            cwd: "/tmp/project".into(),
            repository: Some(RepositoryStatus {
                repo: "project".to_owned(),
                ref_name: "main".to_owned(),
                flags,
            }),
        };

        assert_eq!(
            payload.encode_line(),
            "herdrgit1\t123\tw1:p1\t/tmp/project\t1\tproject\tmain\tdw\n"
        );
    }
}
