use std::io::Read;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use futures_util::{SinkExt, StreamExt};
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::{connect_async, tungstenite::Message};

use ktty_common::crypto;
use ktty_common::messages::*;

use crate::pty::PtyHandle;

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
    /// Returns the PtyHandle on disconnect so caller can reconnect with the same PTY.
    pub async fn run(&self, pty: PtyHandle) -> anyhow::Result<Option<PtyHandle>> {
        // Connect to relay
        let url = format!("{}/ws", self.relay_url);
        eprintln!("[agent] Connecting to relay: {url}");
        let (ws_stream, _) = connect_async(&url).await?;
        eprintln!("[agent] WebSocket connected");
        let (mut ws_tx, mut ws_rx) = ws_stream.split();

        // 1. Send join
        let join = JoinMessage::new(self.room_id.clone());
        ws_tx.send(text_msg(serde_json::to_string(&join)?)).await?;
        eprintln!("[agent] Joined room {}", &self.room_id[..16]);

        // 2. Wait for relay auth token and Flutter client's join message
        eprintln!("[agent] Waiting for Flutter client...");
        let mut relay_auth_token: Option<String> = None;
        loop {
            let timeout = tokio::time::sleep(std::time::Duration::from_secs(5));
            tokio::pin!(timeout);

            tokio::select! {
                msg = ws_rx.next() => {
                    match msg {
                        Some(Ok(Message::Text(ref text))) => {
                            let text_str = text.to_string();
                            eprintln!("[agent] Recv: {}", &text_str[..text_str.len().min(100)]);

                            // Intercept relay auth token
                            if text_str.contains("\"type\"") && text_str.contains("\"auth\"") {
                                if let Ok(val) = serde_json::from_str::<serde_json::Value>(&text_str) {
                                    if let Some(token) = val["token"].as_str() {
                                        relay_auth_token = Some(token.to_string());
                                        eprintln!("[agent] Received relay auth token");
                                        continue;
                                    }
                                }
                            }

                            if text_str.contains("\"action\"") && text_str.contains("\"join\"") {
                                break;
                            }
                            eprintln!("[agent] (not a join, ignoring)");
                            continue;
                        }
                        Some(Ok(Message::Pong(_))) => continue,
                        Some(Ok(Message::Ping(d))) => {
                            let _ = ws_tx.send(Message::Pong(d)).await;
                            continue;
                        }
                        Some(Ok(msg)) => {
                            eprintln!("[agent] Unexpected msg type: {:?}", msg);
                            continue;
                        }
                        None => {
                            eprintln!("[agent] WebSocket stream ended (None)");
                            return Ok(Some(pty));
                        }
                        Some(Err(e)) => {
                            eprintln!("[agent] WebSocket error: {e}");
                            return Ok(Some(pty));
                        }
                    }
                }
                _ = &mut timeout => {
                    let _ = ws_tx.send(Message::Ping(vec![].into())).await;
                    eprintln!("[agent] Keepalive ping sent");
                }
            }
        }
        eprintln!("[agent] Flutter client detected in room");

        // 3. Send boot signal (include auth token if available)
        let mut boot_json = serde_json::to_value(BootSignal::new())?;
        if let Some(ref token) = relay_auth_token {
            boot_json["auth"] = serde_json::Value::String(token.clone());
        }
        ws_tx.send(text_msg(serde_json::to_string(&boot_json)?)).await?;
        eprintln!("[agent] Sent boot signal");

        // 4. Perform ML-KEM handshake
        eprintln!("[agent] Starting ML-KEM handshake...");
        let session_key = self.perform_handshake(&mut ws_tx, &mut ws_rx).await?;
        eprintln!("[agent] ML-KEM handshake complete, encrypted mode");

        // Shared state
        let seq = Arc::new(AtomicU64::new(0));
        let shutdown = Arc::new(AtomicBool::new(false));

        // Split PTY into reader + write handle
        let (pty_reader, pty_write) = pty.take_reader();
        let pty_write = Arc::new(Mutex::new(pty_write));

        // Channel for sending WS messages
        let (ws_send_tx, mut ws_send_rx) = mpsc::unbounded_channel::<Message>();

        // Ring buffer for replay on reconnect
        let ring_buffer = Arc::new(std::sync::Mutex::new(crate::ring_buffer::RingBuffer::new()));

        // Task: drain ws_send channel to WS sink
        let ws_writer_task = tokio::spawn(async move {
            while let Some(msg) = ws_send_rx.recv().await {
                if ws_tx.send(msg).await.is_err() {
                    eprintln!("[agent] WS write failed, writer task ending");
                    break;
                }
            }
        });

        // Task A: PTY reader → WS (encrypted)
        let seq_a = seq.clone();
        let ws_tx_a = ws_send_tx.clone();
        let key_a = session_key;
        let shutdown_a = shutdown.clone();
        let ring_buffer_a = ring_buffer.clone();
        let auth_a = relay_auth_token.clone();

        let pty_reader_task = tokio::task::spawn_blocking(move || {
            let mut reader = pty_reader;
            let mut buf = [0u8; 4096];
            loop {
                if shutdown_a.load(Ordering::Relaxed) {
                    eprintln!("[agent] PTY reader: shutdown signal received");
                    break;
                }
                match reader.read(&mut buf) {
                    Ok(0) => {
                        eprintln!("[agent] PTY reader: EOF (shell exited)");
                        break;
                    }
                    Ok(n) => {
                        let data = buf[..n].to_vec();
                        let current_seq = seq_a.fetch_add(1, Ordering::SeqCst) + 1;

                        // Store plaintext in ring buffer for replay on reconnect
                        {
                            let mut rb = ring_buffer_a.lock().unwrap();
                            rb.push(crate::ring_buffer::Packet {
                                seq: current_seq,
                                msg_type: "pty".into(),
                                payload: data.clone(),
                            });
                        }

                        let payload_b64 = match crypto::encrypt(&key_a, &data) {
                            Ok(encrypted) => BASE64.encode(&encrypted),
                            Err(e) => {
                                eprintln!("[agent] Encrypt error: {e}");
                                continue;
                            }
                        };

                        let envelope =
                            EncryptedEnvelope::new(current_seq, "pty", payload_b64)
                                .with_auth(auth_a.clone());
                        let json = serde_json::to_string(&envelope).unwrap_or_default();
                        if ws_tx_a.send(text_msg(json)).is_err() {
                            eprintln!("[agent] PTY reader: WS channel closed");
                            break;
                        }
                    }
                    Err(e) => {
                        eprintln!("[agent] PTY reader error: {e}");
                        break;
                    }
                }
            }
        });

        // Task B: WS → PTY (decrypt)
        let pty_write_b = pty_write.clone();
        let key_b = session_key;
        let ws_send_tx_b = ws_send_tx.clone();
        let ring_buffer_b = ring_buffer.clone();
        let key_sync = session_key;
        let auth_b = relay_auth_token.clone();

        let ws_reader_task = tokio::spawn(async move {
            loop {
                match ws_rx.next().await {
                    Some(Ok(Message::Text(ref text))) => {
                        let text_str = text.to_string();

                        // Client explicitly disconnected
                        if text_str.contains("\"type\"") && text_str.contains("\"disconnect\"") {
                            eprintln!("[agent] Client sent disconnect");
                            break;
                        }

                        // Relay notified us that the peer dropped
                        if text_str.contains("\"type\"") && text_str.contains("\"peer_disconnect\"") {
                            eprintln!("[agent] Relay reports peer disconnected");
                            break;
                        }

                        // Client reconnected (new join forwarded by relay)
                        if text_str.contains("\"action\"") && text_str.contains("\"join\"") {
                            eprintln!("[agent] Detected client re-join, ending session for reconnect");
                            break;
                        }

                        let envelope: EncryptedEnvelope = match serde_json::from_str(&text_str) {
                            Ok(e) => e,
                            Err(_) => {
                                eprintln!("[agent] WS reader: unparseable: {}", &text_str[..text_str.len().min(80)]);
                                continue;
                            }
                        };

                        let encrypted = match BASE64.decode(&envelope.payload) {
                            Ok(d) => d,
                            Err(e) => {
                                eprintln!("[agent] Base64 decode error: {e}");
                                continue;
                            }
                        };
                        let plaintext = match crypto::decrypt(&key_b, &encrypted) {
                            Ok(d) => d,
                            Err(e) => {
                                eprintln!("[agent] Decrypt error: {e}");
                                continue;
                            }
                        };

                        match envelope.r#type.as_str() {
                            "pty" => {
                                let mut pw = pty_write_b.lock().await;
                                let _ = pw.write_input(&plaintext);
                            }
                            "resize" => {
                                if let Ok(resize) = serde_json::from_slice::<ResizePayload>(&plaintext) {
                                    eprintln!("[agent] Resize: {}x{}", resize.cols, resize.rows);
                                    let pw = pty_write_b.lock().await;
                                    let _ = pw.resize(resize.cols, resize.rows);
                                }
                            }
                            "sys_kill" => {
                                let mut pw = pty_write_b.lock().await;
                                pw.kill_process_group();
                            }
                            "sync_req" => {
                                // Decrypt the sync request payload
                                if let Ok(sync_data) = serde_json::from_slice::<serde_json::Value>(&plaintext) {
                                    let last_seq = sync_data["last_seq"].as_u64().unwrap_or(0);
                                    eprintln!("[agent] Sync request: last_seq={}", last_seq);

                                    let rb = ring_buffer_b.lock().unwrap();
                                    let (packets, dropped) = rb.packets_since(last_seq);
                                    drop(rb); // Release lock before sending

                                    // Warn about dropped packets
                                    if let Some((start, end)) = dropped {
                                        let warn_payload = serde_json::json!({"dropped_start": start, "dropped_end": end});
                                        let warn_bytes = serde_json::to_vec(&warn_payload).unwrap_or_default();
                                        if let Ok(encrypted) = crypto::encrypt(&key_sync, &warn_bytes) {
                                            let envelope = EncryptedEnvelope::new(0, "sync_warn", BASE64.encode(&encrypted))
                                                .with_auth(auth_b.clone());
                                            let json = serde_json::to_string(&envelope).unwrap_or_default();
                                            let _ = ws_send_tx_b.send(text_msg(json));
                                        }
                                    }

                                    // Replay buffered packets (re-encrypt with current session key)
                                    eprintln!("[agent] Replaying {} packets", packets.len());
                                    for pkt in packets {
                                        if let Ok(encrypted) = crypto::encrypt(&key_sync, &pkt.payload) {
                                            let envelope = EncryptedEnvelope::new(pkt.seq, &pkt.msg_type, BASE64.encode(&encrypted))
                                                .with_auth(auth_b.clone());
                                            let json = serde_json::to_string(&envelope).unwrap_or_default();
                                            let _ = ws_send_tx_b.send(text_msg(json));
                                        }
                                    }
                                }
                            }
                            _ => {
                                eprintln!("[agent] Unknown msg type: {}", envelope.r#type);
                            }
                        }
                    }
                    Some(Ok(Message::Close(frame))) => {
                        eprintln!("[agent] WS close frame: {:?}", frame);
                        break;
                    }
                    Some(Ok(Message::Ping(_))) => continue,
                    Some(Ok(_)) => continue,
                    Some(Err(e)) => {
                        eprintln!("[agent] WS reader error: {e}");
                        break;
                    }
                    None => {
                        eprintln!("[agent] WS reader: stream ended (None)");
                        break;
                    }
                }
            }
            eprintln!("[agent] WS reader task ending");
        });

        // Wait for either task to finish
        tokio::select! {
            _ = pty_reader_task => {
                eprintln!("[agent] PTY reader ended (shell exited)");
            }
            _ = ws_reader_task => {
                eprintln!("[agent] WS reader ended (client disconnected or re-joined)");
                shutdown.store(true, Ordering::Relaxed);
            }
        }

        ws_writer_task.abort();
        drop(ws_send_tx);

        // Try to recover the PTY write handle for reuse
        let write_handle = Arc::try_unwrap(pty_write)
            .ok()
            .map(|m| m.into_inner());

        match write_handle {
            Some(wh) => {
                eprintln!("[agent] PTY preserved for reconnect");
                Ok(Some(PtyHandle::from_write_handle(wh)))
            }
            None => {
                eprintln!("[agent] PTY could not be recovered (still in use)");
                Ok(None)
            }
        }
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
        eprintln!("[agent] Sending ML-KEM public key ({} bytes)", ek_bytes.len());
        let offer = HandshakeOffer::new(BASE64.encode(ek_bytes.as_slice()));
        ws_tx
            .send(text_msg(serde_json::to_string(&offer)?))
            .await
            .map_err(|e| anyhow::anyhow!("{e}"))?;

        // Wait for Flutter's ciphertext reply
        eprintln!("[agent] Waiting for ML-KEM ciphertext reply...");
        loop {
            match ws_rx.next().await {
                Some(Ok(Message::Text(ref text))) => {
                    let text_str = text.to_string();
                    eprintln!("[agent] Handshake recv: {}", &text_str[..text_str.len().min(80)]);
                    if let Ok(raw) = serde_json::from_str::<RawMessage>(&text_str) {
                        if raw.is_handshake() {
                            if let Some(ct_b64) = &raw.mlkem_ciphertext {
                                let ct_bytes = BASE64.decode(ct_b64)?;
                                eprintln!("[agent] Received ciphertext ({} bytes)", ct_bytes.len());

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
                                eprintln!("[agent] Sent HMAC verification");

                                return Ok(key);
                            }
                        }
                    }
                    eprintln!("[agent] Handshake: ignoring non-ciphertext message");
                }
                Some(Ok(_)) => continue,
                Some(Err(e)) => {
                    return Err(anyhow::anyhow!("WebSocket error during handshake: {e}"));
                }
                None => {
                    return Err(anyhow::anyhow!("WebSocket closed during handshake"));
                }
            }
        }
    }
}
