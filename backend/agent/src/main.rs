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
    loop {
        eprintln!("Spawning PTY (tmux)...");
        let pty_handle = match pty::PtyHandle::spawn_tmux(cli.cols, cli.rows) {
            Ok(h) => h,
            Err(e) => {
                eprintln!("Failed to spawn PTY: {e}");
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                continue;
            }
        };

        eprintln!("Connecting to relay: {}", cli.relay_url);
        let sess = session::Session::new(cli.relay_url.clone(), derived_key);

        match sess.run(pty_handle).await {
            Ok(()) => eprintln!("Session ended, reconnecting..."),
            Err(e) => eprintln!("Session error: {e}, reconnecting..."),
        }

        // Brief delay before reconnect
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    }
}
