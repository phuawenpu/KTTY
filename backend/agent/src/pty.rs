use portable_pty::{CommandBuilder, MasterPty, PtySize, native_pty_system};
use std::io::{Read, Write};

pub struct PtyHandle {
    master: Box<dyn MasterPty + Send>,
    reader: Box<dyn Read + Send>,
    writer: Box<dyn Write + Send>,
    child: Box<dyn portable_pty::Child + Send + Sync>,
}

impl PtyHandle {
    /// Spawn tmux inside a PTY. If tmux has an existing session, reattach.
    /// This ensures the terminal session survives agent restarts.
    pub fn spawn_tmux(cols: u16, rows: u16) -> anyhow::Result<Self> {
        let pty_system = native_pty_system();

        let pair = pty_system.openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;

        // Use tmux for session persistence across agent restarts.
        // Named session 'ktty' so we can reattach after crash/restart.
        let mut cmd = CommandBuilder::new("bash");
        cmd.arg("-c");
        cmd.arg("TERM=xterm-256color tmux new-session -A -s ktty");
        cmd.env("TERM", "xterm-256color");

        let child = pair.slave.spawn_command(cmd)?;

        // Drop slave — we only need the master side
        drop(pair.slave);

        let reader = pair.master.try_clone_reader()?;
        let writer = pair.master.take_writer()?;

        Ok(Self {
            master: pair.master,
            reader,
            writer,
            child,
        })
    }

    /// Resize the PTY (triggers SIGWINCH on the child process).
    pub fn resize(&self, cols: u16, rows: u16) -> anyhow::Result<()> {
        self.master.resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;
        Ok(())
    }

    /// Write bytes to PTY input (user keystrokes from Flutter).
    pub fn write_input(&mut self, data: &[u8]) -> anyhow::Result<()> {
        self.writer.write_all(data)?;
        self.writer.flush()?;
        Ok(())
    }

    /// Read bytes from PTY output (terminal output to send to Flutter).
    /// This is a blocking call — use from a dedicated thread.
    pub fn read_output(&mut self, buf: &mut [u8]) -> anyhow::Result<usize> {
        let n = self.reader.read(buf)?;
        Ok(n)
    }

    /// Send SIGKILL to the child process group.
    pub fn kill_process_group(&mut self) {
        // Try portable-pty's kill first
        let _ = self.child.kill();

        // Also try process group kill via libc for thorough cleanup
        #[cfg(unix)]
        {
            if let Some(pid) = self.child.process_id() {
                unsafe {
                    libc::kill(-(pid as i32), libc::SIGKILL);
                }
            }
        }
    }

    /// Take the reader for use in a separate thread.
    pub fn take_reader(self) -> (Box<dyn Read + Send>, PtyWriteHandle) {
        (
            self.reader,
            PtyWriteHandle {
                master: self.master,
                writer: self.writer,
                child: self.child,
            },
        )
    }
}

/// Handle for writing to PTY and controlling it (resize, kill).
/// Separated from reader so they can live in different tasks.
pub struct PtyWriteHandle {
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    child: Box<dyn portable_pty::Child + Send + Sync>,
}

impl PtyWriteHandle {
    pub fn resize(&self, cols: u16, rows: u16) -> anyhow::Result<()> {
        self.master.resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;
        Ok(())
    }

    pub fn write_input(&mut self, data: &[u8]) -> anyhow::Result<()> {
        self.writer.write_all(data)?;
        self.writer.flush()?;
        Ok(())
    }

    pub fn kill_process_group(&mut self) {
        let _ = self.child.kill();

        #[cfg(unix)]
        {
            if let Some(pid) = self.child.process_id() {
                unsafe {
                    libc::kill(-(pid as i32), libc::SIGKILL);
                }
            }
        }
    }
}
