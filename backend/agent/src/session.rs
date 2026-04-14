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

fn text_msg(s: String) -> Message {
    Message::Text(s.into())
}

pub struct Session {
    relay_url: String,
    derived_key: [u8; 32],
    room_id: String,
}

/// Why the PTY<->WS bridge loop exited.
enum BridgeExit {
    /// Flutter peer disconnected or relay sent peer_disconnect
    PeerDisconnected,
    /// New Flutter peer joined while bridge was active
    PeerRejoined,
    /// WebSocket connection to relay died
    WsError,
    /// PTY/shell process exited
    PtyExited,
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

    /// Main session loop. Connects to relay once, then loops internally:
    /// wait for Flutter client → handshake → bridge PTY ↔ WS → on disconnect, repeat.
    ///
    /// The agent stays connected to the relay across Flutter reconnects,
    /// eliminating the race condition where both sides try to rejoin simultaneously.
    ///
    /// Returns `Ok(Some(pty))` if the relay connection dies (caller should reconnect).
    /// Returns `Ok(None)` if the shell exited (caller should respawn PTY).
    pub async fn run(&self, pty: PtyHandle) -> anyhow::Result<Option<PtyHandle>> {
        // Connect to relay
        let base = self.relay_url.trim_end_matches('/');
        let url = if base.ends_with("/ws") {
            base.to_string()
        } else {
            format!("{base}/ws")
        };
        eprintln!("[agent] Connecting to relay: {url}");
        let (ws_stream, _) = connect_async(&url).await?;
        eprintln!("[agent] WebSocket connected");
        let (ws_tx, mut ws_rx) = ws_stream.split();

        // Channel for sending WS messages (decouples send from read)
        let (ws_send_tx, ws_send_rx) = mpsc::unbounded_channel::<Message>();

        // WS writer task: drains channel → WS sink
        let ws_writer_task = tokio::spawn(async move {
            let mut ws_tx = ws_tx;
            let mut ws_send_rx = ws_send_rx;
            while let Some(msg) = ws_send_rx.recv().await {
                if ws_tx.send(msg).await.is_err() {
                    eprintln!("[agent] WS write failed, writer ending");
                    break;
                }
            }
        });

        // 1. Join room
        let join = JoinMessage::new(self.room_id.clone());
        ws_send_tx.send(text_msg(serde_json::to_string(&join)?))?;
        eprintln!("[agent] Joined room {}", &self.room_id[..16]);

        // 2. Wait for relay auth token and first Flutter client
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
                        Some(Ok(Message::Ping(d))) => {
                            eprintln!("[agent] init: Got Ping from relay, sending Pong");
                            let _ = ws_send_tx.send(Message::Pong(d));
                            continue;
                        }
                        Some(Ok(Message::Pong(_))) => {
                            eprintln!("[agent] init: Got Pong from relay");
                            continue;
                        }
                        Some(Ok(msg)) => {
                            eprintln!("[agent] init: Unexpected msg type: {:?}", msg);
                            continue;
                        }
                        None => {
                            eprintln!("[agent] init: WS stream ended (None)");
                            ws_writer_task.abort();
                            return Ok(Some(pty));
                        }
                        Some(Err(e)) => {
                            eprintln!("[agent] init: WS error: {e}");
                            ws_writer_task.abort();
                            return Ok(Some(pty));
                        }
                    }
                }
                _ = &mut timeout => {
                    let _ = ws_send_tx.send(Message::Ping(vec![].into()));
                    eprintln!("[agent] init: Keepalive ping sent");
                }
            }
        }
        eprintln!("[agent] Flutter client detected in room");

        // 3. Split PTY into reader channel + write handle
        let (pty_reader, pty_write) = pty.take_reader();
        let pty_write = Arc::new(Mutex::new(pty_write));

        // PTY reader → channel (persists across Flutter reconnects within this WS session)
        let (pty_data_tx, mut pty_data_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let _pty_reader_task = tokio::task::spawn_blocking(move || {
            let mut reader = pty_reader;
            let mut buf = [0u8; 4096];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => {
                        eprintln!("[agent] PTY EOF (shell exited)");
                        break;
                    }
                    Ok(n) => {
                        if pty_data_tx.send(buf[..n].to_vec()).is_err() {
                            eprintln!("[agent] PTY reader: channel closed");
                            break;
                        }
                    }
                    Err(e) => {
                        eprintln!("[agent] PTY read error: {e}");
                        break;
                    }
                }
            }
        });

        // Ring buffer and sequence counter persist across Flutter reconnects
        let ring_buffer = Arc::new(std::sync::Mutex::new(crate::ring_buffer::RingBuffer::new()));
        let seq = Arc::new(AtomicU64::new(0));

        // === RECONNECT LOOP ===
        // Agent stays connected to relay. On Flutter disconnect, waits for
        // re-join and performs a fresh ML-KEM handshake without leaving the room.
        let mut skip_wait = true; // First client already joined above

        loop {
            // Wait for Flutter client join (unless one just joined)
            if !skip_wait {
                eprintln!("[agent] Waiting for Flutter client to rejoin...");
                let mut pty_alive = true;
                let mut keepalive =
                    tokio::time::interval(std::time::Duration::from_secs(15));
                keepalive.tick().await; // skip immediate tick
                let mut last_ws_rx = tokio::time::Instant::now();
                loop {
                    tokio::select! {
                        pty_result = pty_data_rx.recv(), if pty_alive => {
                            match pty_result {
                                Some(data) => {
                                    // Keep draining PTY into ring buffer while waiting
                                    let s = seq.fetch_add(1, Ordering::SeqCst) + 1;
                                    ring_buffer.lock().unwrap().push(
                                        crate::ring_buffer::Packet {
                                            seq: s,
                                            msg_type: "pty".into(),
                                            payload: data,
                                        },
                                    );
                                }
                                None => {
                                    eprintln!("[agent] PTY exited while waiting for client");
                                    pty_alive = false;
                                }
                            }
                        }
                        msg = ws_rx.next() => {
                            last_ws_rx = tokio::time::Instant::now();
                            match msg {
                                Some(Ok(Message::Text(ref text))) => {
                                    let ts = text.to_string();
                                    eprintln!("[agent] wait: Got Text: {}", &ts[..ts.len().min(120)]);
                                    if ts.contains("\"action\"") && ts.contains("\"join\"") {
                                        eprintln!("[agent] wait: Flutter client rejoined!");
                                        break;
                                    }
                                }
                                Some(Ok(Message::Ping(d))) => {
                                    eprintln!("[agent] wait: Got Ping from relay, sending Pong");
                                    let _ = ws_send_tx.send(Message::Pong(d));
                                }
                                Some(Ok(Message::Pong(_))) => {
                                    eprintln!("[agent] wait: Got Pong from relay");
                                }
                                Some(Ok(other)) => {
                                    eprintln!("[agent] wait: Got other msg: {:?}", other);
                                }
                                None => {
                                    eprintln!("[agent] wait: WS stream ended (None)");
                                    ws_writer_task.abort();
                                    drop(pty_data_rx);
                                    let wh = Arc::try_unwrap(pty_write)
                                        .ok()
                                        .map(|m| m.into_inner());
                                    return Ok(wh.map(PtyHandle::from_write_handle));
                                }
                                Some(Err(e)) => {
                                    eprintln!("[agent] wait: WS error: {e}");
                                    ws_writer_task.abort();
                                    drop(pty_data_rx);
                                    let wh = Arc::try_unwrap(pty_write)
                                        .ok()
                                        .map(|m| m.into_inner());
                                    return Ok(wh.map(PtyHandle::from_write_handle));
                                }
                            }
                        }
                        _ = keepalive.tick() => {
                            let elapsed = last_ws_rx.elapsed().as_secs();
                            eprintln!("[agent] wait: Heartbeat tick (last WS rx {}s ago)", elapsed);
                            if elapsed > 45 {
                                eprintln!("[agent] wait: No WS activity for 45s, connection dead");
                                ws_writer_task.abort();
                                drop(pty_data_rx);
                                let wh = Arc::try_unwrap(pty_write)
                                    .ok()
                                    .map(|m| m.into_inner());
                                return Ok(wh.map(PtyHandle::from_write_handle));
                            }
                            let _ = ws_send_tx.send(Message::Ping(vec![].into()));
                            eprintln!("[agent] wait: Sent keepalive ping");
                        }
                    }
                }
            }
            skip_wait = false;

            // Send boot signal
            let mut boot_json = serde_json::to_value(BootSignal::new())?;
            if let Some(ref token) = relay_auth_token {
                boot_json["auth"] = serde_json::Value::String(token.clone());
            }
            ws_send_tx.send(text_msg(serde_json::to_string(&boot_json)?))?;
            eprintln!("[agent] Sent boot signal");

            // ML-KEM handshake → new session key
            eprintln!("[agent] Starting ML-KEM handshake...");
            let session_key =
                match self.perform_handshake(&ws_send_tx, &mut ws_rx, &relay_auth_token).await {
                    Ok(key) => key,
                    Err(e) => {
                        eprintln!("[agent] Handshake failed: {e}, waiting for new client");
                        continue;
                    }
                };
            let session_id = crypto::session_id(&session_key);
            eprintln!("[agent] Handshake complete, encrypted mode");

            // Bridge PTY ↔ WS with this session's key
            let exit = self
                .bridge_loop(
                    &session_key,
                    &session_id,
                    &ws_send_tx,
                    &mut ws_rx,
                    &mut pty_data_rx,
                    &pty_write,
                    &ring_buffer,
                    &seq,
                    &relay_auth_token,
                )
                .await;

            match exit {
                BridgeExit::PeerDisconnected => {
                    eprintln!("[agent] Peer disconnected, staying in room");
                    // skip_wait is false → will wait for new join at top of loop
                    continue;
                }
                BridgeExit::PeerRejoined => {
                    eprintln!("[agent] New peer joined, re-handshaking");
                    skip_wait = true; // Client already joined, skip waiting
                    continue;
                }
                BridgeExit::WsError => {
                    eprintln!("[agent] WS connection lost, returning PTY");
                    ws_writer_task.abort();
                    drop(pty_data_rx);
                    let wh = Arc::try_unwrap(pty_write)
                        .ok()
                        .map(|m| m.into_inner());
                    return Ok(wh.map(PtyHandle::from_write_handle));
                }
                BridgeExit::PtyExited => {
                    eprintln!("[agent] Shell exited");
                    ws_writer_task.abort();
                    return Ok(None);
                }
            }
        }
    }

    /// Bridge PTY data ↔ encrypted WS messages until a disconnect or error.
    async fn bridge_loop<R>(
        &self,
        key: &[u8; 32],
        session_id: &str,
        ws_send: &mpsc::UnboundedSender<Message>,
        ws_rx: &mut R,
        pty_rx: &mut mpsc::UnboundedReceiver<Vec<u8>>,
        pty_write: &Arc<Mutex<crate::pty::PtyWriteHandle>>,
        ring_buf: &Arc<std::sync::Mutex<crate::ring_buffer::RingBuffer>>,
        seq: &Arc<AtomicU64>,
        auth: &Option<String>,
    ) -> BridgeExit
    where
        R: StreamExt<Item = Result<Message, tokio_tungstenite::tungstenite::Error>>
            + Unpin,
    {
        let mut keepalive =
            tokio::time::interval(std::time::Duration::from_secs(15));
        keepalive.tick().await; // skip immediate tick
        let mut last_ws_rx = tokio::time::Instant::now();

        loop {
            tokio::select! {
                pty_result = pty_rx.recv() => {
                    match pty_result {
                        Some(data) => {
                            let s = seq.fetch_add(1, Ordering::SeqCst) + 1;

                            // Store plaintext in ring buffer for replay
                            ring_buf.lock().unwrap().push(
                                crate::ring_buffer::Packet {
                                    seq: s,
                                    msg_type: "pty".into(),
                                    payload: data.clone(),
                                },
                            );

                            // Encrypt and send
                            match crypto::encrypt(key, &data) {
                                Ok(enc) => {
                                    let env = EncryptedEnvelope::new(
                                        s, session_id, "pty", BASE64.encode(&enc),
                                    )
                                    .with_auth(auth.clone());
                                    let json = serde_json::to_string(&env)
                                        .unwrap_or_default();
                                    if ws_send.send(text_msg(json)).is_err() {
                                        return BridgeExit::WsError;
                                    }
                                }
                                Err(e) => {
                                    eprintln!("[agent] Encrypt error: {e}");
                                }
                            }
                        }
                        None => return BridgeExit::PtyExited,
                    }
                }

                msg = ws_rx.next() => {
                    last_ws_rx = tokio::time::Instant::now();
                    match msg {
                        Some(Ok(Message::Text(ref text))) => {
                            let t = text.to_string();

                            // Client explicitly disconnected
                            if t.contains("\"type\"")
                                && t.contains("\"disconnect\"")
                            {
                                eprintln!("[agent] Client sent disconnect");
                                return BridgeExit::PeerDisconnected;
                            }

                            // Relay reports peer dropped
                            if t.contains("\"type\"")
                                && t.contains("\"peer_disconnect\"")
                            {
                                eprintln!(
                                    "[agent] Relay reports peer disconnected"
                                );
                                return BridgeExit::PeerDisconnected;
                            }

                            // New client joined (relay forwarded join)
                            if t.contains("\"action\"")
                                && t.contains("\"join\"")
                            {
                                eprintln!(
                                    "[agent] New client joined (re-join)"
                                );
                                return BridgeExit::PeerRejoined;
                            }

                            // Parse encrypted envelope
                            let env: EncryptedEnvelope =
                                match serde_json::from_str(&t) {
                                    Ok(e) => e,
                                    Err(_) => {
                                        eprintln!(
                                            "[agent] Unparseable: {}",
                                            &t[..t.len().min(80)]
                                        );
                                        continue;
                                    }
                                };

                            if env.session_id != session_id {
                                eprintln!(
                                    "[agent] Dropping stale-session envelope seq={} type={} session={} current={}",
                                    env.seq, env.r#type, env.session_id, session_id
                                );
                                continue;
                            }

                            let encrypted = match BASE64.decode(&env.payload) {
                                Ok(d) => d,
                                Err(e) => {
                                    eprintln!("[agent] Base64 error: {e}");
                                    continue;
                                }
                            };
                            let plain = match crypto::decrypt(key, &encrypted) {
                                Ok(d) => d,
                                Err(e) => {
                                    eprintln!("[agent] Decrypt error: {e}");
                                    continue;
                                }
                            };

                            match env.r#type.as_str() {
                                "pty" => {
                                    let mut pw = pty_write.lock().await;
                                    let _ = pw.write_input(&plain);
                                }
                                "resize" => {
                                    if let Ok(r) = serde_json::from_slice::<
                                        ResizePayload,
                                    >(
                                        &plain
                                    ) {
                                        eprintln!(
                                            "[agent] Resize: {}x{}",
                                            r.cols, r.rows
                                        );
                                        let pw = pty_write.lock().await;
                                        let _ = pw.resize(r.cols, r.rows);
                                    }
                                }
                                "sys_kill" => {
                                    let mut pw = pty_write.lock().await;
                                    pw.kill_process_group();
                                }
                                "sync_req" => {
                                    self.handle_sync_req(
                                        key, session_id, ws_send, ring_buf, auth, &plain,
                                    );
                                }
                                other => {
                                    eprintln!(
                                        "[agent] Unknown type: {other}"
                                    );
                                }
                            }
                        }
                        Some(Ok(Message::Ping(d))) => {
                            eprintln!("[agent] bridge: Got Ping, sending Pong");
                            let _ = ws_send.send(Message::Pong(d));
                        }
                        Some(Ok(Message::Pong(_))) => {
                            eprintln!("[agent] bridge: Got Pong");
                        }
                        Some(Ok(Message::Close(f))) => {
                            eprintln!("[agent] bridge: WS close frame: {:?}", f);
                            return BridgeExit::WsError;
                        }
                        Some(Ok(other)) => {
                            eprintln!("[agent] bridge: Other msg: {:?}", other);
                        }
                        Some(Err(e)) => {
                            eprintln!("[agent] bridge: WS error: {e}");
                            return BridgeExit::WsError;
                        }
                        None => {
                            eprintln!("[agent] bridge: WS stream ended (None)");
                            return BridgeExit::WsError;
                        }
                    }
                }

                _ = keepalive.tick() => {
                    let elapsed = last_ws_rx.elapsed().as_secs();
                    eprintln!("[agent] bridge: Heartbeat tick (last WS rx {}s ago)", elapsed);
                    if elapsed > 45 {
                        eprintln!("[agent] bridge: No WS activity for 45s, connection dead");
                        return BridgeExit::WsError;
                    }
                    let _ = ws_send.send(Message::Ping(vec![].into()));
                }
            }
        }
    }

    /// Handle a sync_req: replay ring buffer packets re-encrypted with current key.
    fn handle_sync_req(
        &self,
        key: &[u8; 32],
        session_id: &str,
        ws_send: &mpsc::UnboundedSender<Message>,
        ring_buf: &Arc<std::sync::Mutex<crate::ring_buffer::RingBuffer>>,
        auth: &Option<String>,
        plain: &[u8],
    ) {
        let sync_data = match serde_json::from_slice::<SyncReqPayload>(plain) {
            Ok(d) => d,
            Err(e) => {
                eprintln!("[agent] Invalid sync request payload: {e}");
                return;
            }
        };
        if sync_data.session_id != session_id {
            eprintln!(
                "[agent] Dropping stale sync request for session {} (current {})",
                sync_data.session_id, session_id
            );
            return;
        }
        let last_seq = sync_data.last_seq;
        eprintln!("[agent] Sync request: last_seq={last_seq}");

        let rb = ring_buf.lock().unwrap();
        let (packets, dropped) = rb.packets_since(last_seq);
        drop(rb);

        // Warn about dropped packets
        if let Some((start, end)) = dropped {
            let warn = serde_json::json!({"dropped_start": start, "dropped_end": end});
            let warn_bytes = serde_json::to_vec(&warn).unwrap_or_default();
            if let Ok(enc) = crypto::encrypt(key, &warn_bytes) {
                let env = EncryptedEnvelope::new(0, session_id, "sync_warn", BASE64.encode(&enc))
                    .with_auth(auth.clone());
                let _ = ws_send
                    .send(text_msg(serde_json::to_string(&env).unwrap_or_default()));
            }
        }

        // Replay buffered packets re-encrypted with current session key
        eprintln!("[agent] Replaying {} packets", packets.len());
        for pkt in packets {
            if let Ok(enc) = crypto::encrypt(key, &pkt.payload) {
                let env = EncryptedEnvelope::new(pkt.seq, session_id, &pkt.msg_type, BASE64.encode(&enc))
                    .with_auth(auth.clone());
                let _ = ws_send
                    .send(text_msg(serde_json::to_string(&env).unwrap_or_default()));
            }
        }
    }

    /// Perform ML-KEM 768 key exchange with the Flutter client.
    async fn perform_handshake<R>(
        &self,
        ws_send: &mpsc::UnboundedSender<Message>,
        ws_rx: &mut R,
        relay_auth_token: &Option<String>,
    ) -> anyhow::Result<[u8; 32]>
    where
        R: StreamExt<Item = Result<Message, tokio_tungstenite::tungstenite::Error>>
            + Unpin,
    {
        use ml_kem::kem::Decapsulate;
        use ml_kem::{EncodedSizeUser, KemCore, MlKem768};

        let mut rng = rand::thread_rng();
        let (dk, ek) = MlKem768::generate(&mut rng);

        // Send encapsulation key (public key) — must include the relay's
        // auth token, since the relay no longer exempts handshake messages
        // from token validation.
        let ek_bytes = ek.as_bytes();
        eprintln!(
            "[agent] Sending ML-KEM public key ({} bytes)",
            ek_bytes.len()
        );
        let offer = HandshakeOffer::new(BASE64.encode(ek_bytes.as_slice()));
        let mut offer_json = serde_json::to_value(&offer)?;
        if let Some(token) = relay_auth_token.as_ref() {
            offer_json["auth"] = serde_json::Value::String(token.clone());
        }
        ws_send.send(text_msg(serde_json::to_string(&offer_json)?))?;

        // Wait for Flutter's ciphertext reply
        eprintln!("[agent] Waiting for ML-KEM ciphertext...");
        loop {
            match ws_rx.next().await {
                Some(Ok(Message::Text(ref text))) => {
                    let text_str = text.to_string();
                    eprintln!(
                        "[agent] Handshake recv: {}",
                        &text_str[..text_str.len().min(80)]
                    );
                    if let Ok(raw) = serde_json::from_str::<RawMessage>(&text_str) {
                        if raw.is_handshake() {
                            if let Some(ct_b64) = &raw.mlkem_ciphertext {
                                let ct_bytes = BASE64.decode(ct_b64)?;
                                eprintln!(
                                    "[agent] Received ciphertext ({} bytes)",
                                    ct_bytes.len()
                                );

                                let ct =
                                    ml_kem::Ciphertext::<MlKem768>::from_slice(
                                        &ct_bytes,
                                    );
                                let shared_secret =
                                    dk.decapsulate(ct).map_err(|_| {
                                        anyhow::anyhow!(
                                            "ML-KEM decapsulation failed"
                                        )
                                    })?;

                                let mut key = [0u8; 32];
                                key.copy_from_slice(shared_secret.as_slice());

                                // HMAC verification
                                let hmac =
                                    crypto::compute_hmac(&self.derived_key, &key);
                                let mut hmac_msg = serde_json::json!({
                                    "type": "handshake",
                                    "hmac": BASE64.encode(&hmac),
                                });
                                if let Some(token) = relay_auth_token.as_ref() {
                                    hmac_msg["auth"] =
                                        serde_json::Value::String(token.clone());
                                }
                                ws_send.send(text_msg(
                                    serde_json::to_string(&hmac_msg)?,
                                ))?;
                                eprintln!("[agent] Sent HMAC verification");

                                return Ok(key);
                            }
                        }
                    }
                    eprintln!(
                        "[agent] Handshake: ignoring non-ciphertext message"
                    );
                }
                Some(Ok(Message::Ping(d))) => {
                    let _ = ws_send.send(Message::Pong(d));
                }
                Some(Ok(_)) => continue,
                Some(Err(e)) => {
                    return Err(anyhow::anyhow!(
                        "WebSocket error during handshake: {e}"
                    ));
                }
                None => {
                    return Err(anyhow::anyhow!(
                        "WebSocket closed during handshake"
                    ));
                }
            }
        }
    }
}
