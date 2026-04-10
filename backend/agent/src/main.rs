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

    /// Generate an encrypted URL token for PWA use and exit.
    /// The URL is encrypted with the PIN so only the correct PIN can decrypt it.
    #[arg(long)]
    encrypt_url: bool,
}

const VERSION: u32 = 7;
const BUILD_TIME: &str = env!("KTTY_BUILD_TIME");

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    eprintln!("ktty-agent v{VERSION} (built {BUILD_TIME})");

    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Failed to install rustls crypto provider");
    env_logger::init();

    let cli = Cli::parse();

    // Prompt for PIN
    eprint!("Enter PIN (8+ digits): ");
    std::io::stderr().flush()?;
    let mut pin = String::new();
    std::io::stdin().read_line(&mut pin)?;
    // Strip to digits only
    let pin: String = pin.trim().chars().filter(|c| c.is_ascii_digit()).collect();

    // Enforce minimum PIN length. The room id is `hex(Argon2id(pin))` and is
    // visible to the relay, so a short PIN can be cracked offline by anyone
    // who sees a join. 8 digits gives ~10^8 candidates → months on a single
    // CPU core at our Argon2 cost; longer is better.
    if pin.len() < 8 {
        eprintln!("PIN must be at least 8 digits (got {})", pin.len());
        std::process::exit(1);
    }
    // Never log the PIN itself — it would end up in scroll-back, journald,
    // and any terminal-recording software. Only the digit count is safe.
    eprintln!("PIN received ({} digits)", pin.len());

    // Derive key (this takes a few seconds due to Argon2id)
    eprintln!("Deriving key...");
    let derived_key = crypto::derive_key(&pin)?;
    let room_id = crypto::room_id(&derived_key);
    eprintln!("Room ID: {room_id}");

    // --encrypt-url: generate encrypted URL token for PWA and exit
    if cli.encrypt_url {
        let url_bytes = cli.relay_url.as_bytes();
        let encrypted = crypto::encrypt(&derived_key, url_bytes)?;
        let hex_token = hex::encode(&encrypted);
        eprintln!("\n=== Encrypted URL Token (for PWA) ===");
        println!("{hex_token}");
        eprintln!("=====================================");
        eprintln!("Paste this token into the PWA 'Encrypted URL' field.");
        std::process::exit(0);
    }

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
            Ok(Some(recovered_pty)) => {
                eprintln!("[agent] Session ended, PTY preserved. Reconnecting...");
                pty_handle = Some(recovered_pty);
            }
            Ok(None) => {
                eprintln!("[agent] Session ended, shell exited. Will respawn...");
                // pty_handle stays None → will respawn next iteration
            }
            Err(e) => {
                eprintln!("[agent] Session error: {e}, reconnecting...");
                // PTY is gone (moved into session), need new one
            }
        }

        // Brief delay before reconnect/respawn
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    }
}
