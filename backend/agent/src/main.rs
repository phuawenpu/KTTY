mod pty;
mod ring_buffer;
mod session;

use clap::Parser;
use ktty_common::crypto;
use std::io::Write;

#[derive(Parser)]
#[command(name = "ktty-agent", about = "KTTY Host Agent")]
struct Cli {
    /// WebSocket URL of the Cloud Relay (e.g. ws://relay.example.com:8080)
    #[arg(long, env = "KTTY_RELAY_URL")]
    relay_url: String,

    /// Initial terminal columns
    #[arg(long, default_value = "80")]
    cols: u16,

    /// Initial terminal rows
    #[arg(long, default_value = "24")]
    rows: u16,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Failed to install rustls crypto provider");
    env_logger::init();

    let cli = Cli::parse();

    // Prompt for PIN
    eprint!("Enter PIN: ");
    std::io::stderr().flush()?;
    let mut pin = String::new();
    std::io::stdin().read_line(&mut pin)?;
    let pin = pin.trim().to_string();

    if pin.is_empty() {
        eprintln!("PIN cannot be empty");
        std::process::exit(1);
    }

    // Derive key (this takes a few seconds due to Argon2id)
    eprintln!("Deriving key...");
    let derived_key = crypto::derive_key(&pin)?;
    let room_id = crypto::room_id(&derived_key);
    eprintln!("Room ID: {room_id}");

    // Main loop: spawn PTY, connect, reconnect on disconnect
    // PTY persists across reconnects; only respawn if shell exits
    let mut pty_handle: Option<pty::PtyHandle> = None;

    loop {
        // Spawn PTY if we don't have one
        if pty_handle.is_none() {
            eprintln!("[agent] Spawning new shell...");
            match pty::PtyHandle::spawn_tmux(cli.cols, cli.rows) {
                Ok(h) => pty_handle = Some(h),
                Err(e) => {
                    eprintln!("[agent] Failed to spawn PTY: {e}");
                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                    continue;
                }
            }
        }

        eprintln!("[agent] Connecting to relay: {}", cli.relay_url);
        let sess = session::Session::new(cli.relay_url.clone(), derived_key);

        match sess.run(pty_handle.take().unwrap()).await {
            Ok(()) => {
                eprintln!("[agent] Session ended (shell exited), respawning...");
                // Shell exited — pty_handle is None, will respawn next iteration
            }
            Err(e) => {
                eprintln!("[agent] Session error: {e}, reconnecting...");
                // WS error — PTY is gone (moved into session), need new one
            }
        }

        // Brief delay before reconnect/respawn
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    }
}
