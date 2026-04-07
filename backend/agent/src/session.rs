use std::io::Read;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use futures_util::{SinkExt, StreamExt};
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::{connect_async, tungstenite::Message};

use ktty_common::crypto;
use ktty_common::messages::*;

use crate::pty::PtyHandle;
use crate::ring_buffer::{Packet, RingBuffer};

fn text_msg(s: String) -> Message {
    Message::Text(s.into())
}

pub struct Session {
    relay_url: String,
    derived_key: [u8; 32],
    room_id: String,
}

impl Session {
    pub fn new(relay_url: String, derived_key: [u8; 32]) -> Self {
        let room_id = crypto::room_id(&derived_key);
        Self {
            relay_url,
            derived_key,
            room_id,
        }
    }

    /// Main session loop. Connects to relay, performs handshake, bridges PTY <-> WS.
    /// Returns on disconnect so caller can reconnect.
    pub async fn run(&self, pty: PtyHandle) -> anyhow::Result<()> {
        // Connect to relay
        let url = format!("{}/ws", self.relay_url);
        let (ws_stream, _) = connect_async(&url).await?;
        let (mut ws_tx, mut ws_rx) = ws_stream.split();

        // 1. Send join
        let join = JoinMessage::new(self.room_id.clone());
        ws_tx.send(text_msg(serde_json::to_string(&join)?)).await?;
        eprintln!("[agent] Joined room, waiting for Flutter client...");

        // 2. Wait for the Flutter client's join message to be forwarded to us.
        //    Send periodic pings to keep the connection alive.
        eprintln!("[agent] Waiting for Flutter client (sending keepalive pings)...");
        loop {
            let timeout = tokio::time::sleep(std::time::Duration::from_secs(5));
            tokio::pin!(timeout);

            tokio::select! {
                msg = ws_rx.next() => {
                    match msg {
                        Some(Ok(Message::Text(ref text))) => {
                            let text_str = text.to_string();
                            eprintln!("[agent] Received: {}", &text_str[..text_str.len().min(80)]);
                            // Only break on join messages from Flutter client
                            // Ignore our own echoed messages (boot, handshake)
                            if text_str.contains("\"action\"") && text_str.contains("\"join\"") {
                                break;
                            }
                            eprintln!("[agent] Ignoring (not a join), continuing to wait...");
                            continue;
                        }
                        Some(Ok(Message::Pong(_))) => continue,
                        Some(Ok(Message::Ping(d))) => {
                            let _ = ws_tx.send(Message::Pong(d)).await;
                            continue;
                        }
                        Some(Ok(_)) => continue,
                        None | Some(Err(_)) => {
                            return Err(anyhow::anyhow!("WebSocket closed while waiting for client"));
                        }
                    }
                }
                _ = &mut timeout => {
                    // Send ping to keep connection alive
                    let _ = ws_tx.send(Message::Ping(vec![].into())).await;
                    eprintln!("[agent] Sent keepalive ping");
                }
            }
        }
        eprintln!("[agent] Flutter client detected in room");

        // 3. Send boot signal (unencrypted)
        let boot = BootSignal::new();
        ws_tx.send(text_msg(serde_json::to_string(&boot)?)).await?;

        // 4. Skip ML-KEM handshake for plain-text demo
        //    TODO: Re-enable once flutter_rust_bridge crypto FFI is implemented
        eprintln!("[agent] Plain-text mode (no encryption)");

        // Consume handshake messages from Flutter (join notification, handshake offer)
        // so they don't interfere with the PTY message loop
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let timeout = tokio::time::sleep_until(deadline);
            tokio::pin!(timeout);
            tokio::select! {
                msg = ws_rx.next() => {
                    match msg {
                        Some(Ok(Message::Text(ref text))) => {
                            let t = text.to_string();
                            eprintln!("[agent] Consuming pre-PTY msg: {}", &t[..t.len().min(60)]);
                            // Once we see encrypted envelopes (seq field), break
                            if t.contains("\"seq\"") {
                                break;
                            }
                        }
                        Some(Ok(Message::Ping(d))) => {
                            let _ = ws_tx.send(Message::Pong(d)).await;
                        }
                        Some(Ok(_)) => continue,
                        None | Some(Err(_)) => {
                            return Err(anyhow::anyhow!("WebSocket closed"));
                        }
                    }
                }
                _ = &mut timeout => {
                    eprintln!("[agent] Done consuming handshake messages");
                    break;
                }
            }
        }

        // Shared state
        let seq = Arc::new(AtomicU64::new(0));
        let ring_buffer = Arc::new(Mutex::new(RingBuffer::new()));

        // Split PTY into reader + write handle
        let (pty_reader, pty_write) = pty.take_reader();
        let pty_write = Arc::new(Mutex::new(pty_write));

        // Channel for sending WS messages
        let (ws_send_tx, mut ws_send_rx) = mpsc::unbounded_channel::<Message>();

        // Task: drain ws_send channel to WS sink
        let ws_writer_task = tokio::spawn(async move {
            while let Some(msg) = ws_send_rx.recv().await {
                if ws_tx.send(msg).await.is_err() {
                    break;
                }
            }
        });

        // Task A: PTY reader → WS (plain base64, encryption TODO after ML-KEM interop fix)
        let seq_a = seq.clone();
        let ws_tx_a = ws_send_tx.clone();

        let pty_reader_task = tokio::task::spawn_blocking(move || {
            let mut reader = pty_reader;
            let mut buf = [0u8; 4096];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        let data = buf[..n].to_vec();
                        let current_seq = seq_a.fetch_add(1, Ordering::SeqCst) + 1;

                        let payload_b64 = BASE64.encode(&data);

                        let envelope =
                            EncryptedEnvelope::new(current_seq, "pty", payload_b64);
                        let json = serde_json::to_string(&envelope).unwrap_or_default();
                        let _ = ws_tx_a.send(text_msg(json));
                    }
                    Err(_) => break,
                }
            }
        });

        // Task B: WS → PTY (plain base64, encryption TODO after ML-KEM interop fix)
        let ws_tx_b = ws_send_tx.clone();
        let pty_write_b = pty_write.clone();

        let ws_reader_task = tokio::spawn(async move {
            while let Some(Ok(msg)) = ws_rx.next().await {
                let text = match &msg {
                    Message::Text(t) => t.to_string(),
                    Message::Close(_) => break,
                    _ => continue,
                };

                let envelope: EncryptedEnvelope = match serde_json::from_str(&text) {
                    Ok(e) => e,
                    Err(_) => continue,
                };

                // Decode plain base64 payload
                let plaintext = match BASE64.decode(&envelope.payload) {
                    Ok(d) => d,
                    Err(_) => continue,
                };

                match envelope.r#type.as_str() {
                    "pty" => {
                        let mut pw = pty_write_b.lock().await;
                        let _ = pw.write_input(&plaintext);
                    }
                    "resize" => {
                        if let Ok(resize) =
                            serde_json::from_slice::<ResizePayload>(&plaintext)
                        {
                            eprintln!("[agent] Resize: {}x{}", resize.cols, resize.rows);
                            let pw = pty_write_b.lock().await;
                            let _ = pw.resize(resize.cols, resize.rows);
                        }
                    }
                    "sys_kill" => {
                        let mut pw = pty_write_b.lock().await;
                        pw.kill_process_group();
                    }
                    _ => {}
                }
            }
        });

        tokio::select! {
            _ = pty_reader_task => {}
            _ = ws_reader_task => {}
        }

        ws_writer_task.abort();
        Ok(())
    }

    async fn perform_handshake<S, R>(
        &self,
        ws_tx: &mut S,
        ws_rx: &mut R,
    ) -> anyhow::Result<[u8; 32]>
    where
        S: SinkExt<Message> + Unpin,
        S::Error: std::error::Error + Send + Sync + 'static,
        R: StreamExt<Item = Result<Message, tokio_tungstenite::tungstenite::Error>>
            + Unpin,
    {
        use ml_kem::kem::Decapsulate;
        use ml_kem::{EncodedSizeUser, KemCore, MlKem768};

        let mut rng = rand::thread_rng();
        let (dk, ek) = MlKem768::generate(&mut rng);

        // Send encapsulation key (public key)
        let ek_bytes = ek.as_bytes();
        let offer = HandshakeOffer::new(BASE64.encode(ek_bytes.as_slice()));
        ws_tx
            .send(text_msg(serde_json::to_string(&offer)?))
            .await
            .map_err(|e| anyhow::anyhow!("{e}"))?;

        // Wait for Flutter's ciphertext reply
        loop {
            match ws_rx.next().await {
                Some(Ok(Message::Text(ref text))) => {
                    let text_str = text.to_string();
                    if let Ok(raw) = serde_json::from_str::<RawMessage>(&text_str) {
                        if raw.is_handshake() {
                            if let Some(ct_b64) = &raw.mlkem_ciphertext {
                                let ct_bytes = BASE64.decode(ct_b64)?;

                                let ct = ml_kem::Ciphertext::<MlKem768>::from_slice(
                                    &ct_bytes,
                                );
                                let shared_secret = dk.decapsulate(ct).map_err(|_| {
                                    anyhow::anyhow!("ML-KEM decapsulation failed")
                                })?;

                                let mut key = [0u8; 32];
                                key.copy_from_slice(shared_secret.as_slice());

                                // HMAC verification
                                let hmac =
                                    crypto::compute_hmac(&self.derived_key, &key);
                                let hmac_msg = serde_json::json!({
                                    "type": "handshake",
                                    "hmac": BASE64.encode(&hmac),
                                });
                                ws_tx
                                    .send(text_msg(
                                        serde_json::to_string(&hmac_msg)?,
                                    ))
                                    .await
                                    .map_err(|e| anyhow::anyhow!("{e}"))?;

                                return Ok(key);
                            }
                        }
                    }
                }
                Some(Ok(_)) => continue,
                _ => return Err(anyhow::anyhow!("WebSocket closed during handshake")),
            }
        }
    }
}
