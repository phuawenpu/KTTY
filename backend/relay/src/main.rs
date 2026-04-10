use axum::{
    Router,
    extract::{
        State,
        ws::{Message, WebSocket, WebSocketUpgrade},
    },
    response::IntoResponse,
    routing::get,
};
use rand::RngCore;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{mpsc, Mutex};

type Tx = mpsc::Sender<Message>;

/// Per-peer outbound channel depth. Bounded so a stalled writer doesn't
/// let the relay accumulate unbounded memory.
const PEER_CHANNEL_CAPACITY: usize = 64;

/// Hard cap on a single inbound text frame from any peer. Anything bigger
/// is dropped before serde_json::from_str even sees it.
const MAX_TEXT_FRAME_BYTES: usize = 64 * 1024;

/// Cap on the entire WebSocket message (sum of all fragments).
const MAX_WS_MESSAGE_BYTES: usize = 256 * 1024;

struct Peer {
    id: u64,
    tx: Tx,
    last_activity: tokio::time::Instant,
    auth_token: String,
}

struct Room {
    peers: Vec<Peer>,
    next_id: u64,
}

impl Room {
    fn new() -> Self {
        Self {
            peers: Vec::new(),
            next_id: 0,
        }
    }

    fn add_peer(&mut self, tx: Tx) -> (u64, String) {
        let id = self.next_id;
        self.next_id += 1;
        // 32 random bytes from OsRng, hex-encoded → 64-char unguessable token.
        // The relay uses this as a "you joined and we said hello" cookie; it
        // is NOT the cryptographic session key (that's the ML-KEM shared
        // secret, derived end-to-end and never seen by the relay). Without
        // it the relay would let any joiner forge handshake messages on
        // behalf of an existing peer slot.
        let mut token_bytes = [0u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut token_bytes);
        let auth_token = hex::encode(token_bytes);
        self.peers.push(Peer {
            id,
            tx,
            last_activity: tokio::time::Instant::now(),
            auth_token: auth_token.clone(),
        });
        (id, auth_token)
    }
}

type RoomMap = Arc<Mutex<HashMap<String, Room>>>;

#[tokio::main]
async fn main() {
    let port = std::env::args()
        .nth(1)
        .and_then(|s| s.parse::<u16>().ok())
        .unwrap_or(8080);

    let rooms: RoomMap = Arc::new(Mutex::new(HashMap::new()));

    let rooms_health = rooms.clone();
    let rooms_cleanup = rooms.clone();

    let app = Router::new()
        .route("/ws", get(ws_handler))
        .route("/health", get(move || health_handler(rooms_health.clone())))
        .with_state(rooms);

    // Background task: evict stale peers every 30s
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(30));
        loop {
            interval.tick().await;
            let mut map = rooms_cleanup.lock().await;
            let now = tokio::time::Instant::now();
            let mut empty_rooms = Vec::new();
            for (room_id, room) in map.iter_mut() {
                room.peers.retain(|p| {
                    let alive = now.duration_since(p.last_activity).as_secs() < 60
                        && p.tx.try_send(Message::Ping(vec![].into())).is_ok();
                    if !alive {
                        eprintln!("[relay] Evicting stale peer {} in room", p.id);
                    }
                    alive
                });
                if room.peers.is_empty() {
                    empty_rooms.push(room_id.clone());
                }
            }
            for room_id in empty_rooms {
                map.remove(&room_id);
                eprintln!("[relay] Removed empty room");
            }
        }
    });

    let addr = format!("0.0.0.0:{port}");
    println!("KTTY Relay listening on ws://{addr}/ws");

    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

async fn health_handler(_rooms: RoomMap) -> impl IntoResponse {
    // Don't leak room/peer counts to anonymous probers — Fly's healthcheck
    // only needs a 2xx + a content-type. The CORS header lets the PWA's
    // dashboard reachability probe succeed when called from a different
    // origin (e.g. https://phuawenpu.github.io). The body is not
    // sensitive — it's a literal "{}" — so a wildcard origin is fine.
    (
        axum::http::StatusCode::OK,
        [
            ("content-type", "application/json"),
            ("access-control-allow-origin", "*"),
            ("cache-control", "no-store"),
        ],
        "{\"status\":\"ok\"}",
    )
}

async fn ws_handler(
    ws: WebSocketUpgrade,
    State(rooms): State<RoomMap>,
) -> impl IntoResponse {
    ws.max_frame_size(MAX_TEXT_FRAME_BYTES)
        .max_message_size(MAX_WS_MESSAGE_BYTES)
        .on_upgrade(move |socket| handle_socket(socket, rooms))
}

async fn handle_socket(socket: WebSocket, rooms: RoomMap) {
    use futures_util::{SinkExt, StreamExt};

    let (mut ws_tx, mut ws_rx) = socket.split();

    // First message must be a join. The relay doesn't yet know who this
    // peer is, so this is the only message that bypasses the auth-token
    // check. Cap its size before parsing so a hostile client can't push
    // megabytes of JSON into serde.
    let room_id = match ws_rx.next().await {
        Some(Ok(Message::Text(text))) => {
            if text.len() > MAX_TEXT_FRAME_BYTES {
                eprintln!("[relay] First message too large ({}), dropping", text.len());
                return;
            }
            match serde_json::from_str::<serde_json::Value>(&text) {
                Ok(val) if val["action"] == "join" => {
                    val["room_id"].as_str().unwrap_or("").to_string()
                }
                _ => return,
            }
        }
        _ => return,
    };

    if room_id.is_empty() {
        eprintln!("[relay] Empty room_id, dropping connection");
        return;
    }

    // Don't log the room id at all — it's derived from the user's PIN and
    // an attacker who sees enough of it can mount an offline Argon2 crack
    // (see SECURITY.md / threat model in README.md).
    eprintln!("[relay] Client joined a room");

    // Bounded channel: a stalled writer can't make us buffer arbitrary bytes.
    let (tx, mut rx) = mpsc::channel::<Message>(PEER_CHANNEL_CAPACITY);
    let tx_auth = tx.clone();

    // Register in room and get our peer ID + auth token
    let peer_id;
    let auth_token;
    let peer_count;
    {
        let mut map = rooms.lock().await;
        let room = map.entry(room_id.clone()).or_insert_with(Room::new);

        // Clean up stale peers — try sending a ping, evict if it fails
        room.peers.retain(|p| p.tx.try_send(Message::Ping(vec![].into())).is_ok());

        if room.peers.len() >= 2 {
            // Evict the least recently active peer (likely a stale connection)
            if let Some(idx) = room.peers.iter().enumerate()
                .min_by_key(|(_, p)| p.last_activity)
                .map(|(i, _)| i)
            {
                let evicted = &room.peers[idx];
                // Notify the evicted peer so it knows to reconnect
                let msg = serde_json::json!({"type": "peer_disconnect", "peer_id": evicted.id});
                let _ = evicted.tx.try_send(Message::Text(serde_json::to_string(&msg).unwrap().into()));
                eprintln!("[relay] Room full, evicting least active peer {}", evicted.id);
                room.peers.remove(idx);
            }
        }

        let (id, token) = room.add_peer(tx);
        peer_id = id;
        auth_token = token;
        peer_count = room.peers.len();
    }
    eprintln!("[relay] Peer {} joined (now {} in room)", peer_id, peer_count);

    // Send auth token back to the joining peer
    {
        let auth_msg = serde_json::json!({"type": "auth", "token": &auth_token});
        let auth_text = Message::Text(serde_json::to_string(&auth_msg).unwrap().into());
        let _ = tx_auth.try_send(auth_text);
    }

    // Notify existing peers that a new client joined by forwarding the join message
    {
        let join_msg = serde_json::json!({"action": "join", "room_id": room_id});
        let join_text = Message::Text(serde_json::to_string(&join_msg).unwrap().into());
        let map = rooms.lock().await;
        if let Some(room) = map.get(&room_id) {
            for peer in &room.peers {
                if peer.id != peer_id {
                    let _ = peer.tx.try_send(join_text.clone());
                    eprintln!("[relay] Notified peer {} of new join", peer.id);
                }
            }
        }
    }

    // Task: forward from channel to WebSocket sink + send periodic pings.
    // All writes have a 10s timeout to detect stuck connections (e.g. Fly proxy stall).
    let write_task = tokio::spawn(async move {
        let mut ping_interval = tokio::time::interval(std::time::Duration::from_secs(15));
        ping_interval.tick().await; // skip immediate tick
        loop {
            tokio::select! {
                msg = rx.recv() => {
                    match msg {
                        Some(m) => {
                            match tokio::time::timeout(
                                std::time::Duration::from_secs(10),
                                ws_tx.send(m),
                            ).await {
                                Ok(Ok(())) => {}
                                Ok(Err(e)) => {
                                    eprintln!("[relay] Write error for peer: {e}");
                                    break;
                                }
                                Err(_) => {
                                    eprintln!("[relay] Write timeout (10s), connection stuck");
                                    break;
                                }
                            }
                        }
                        None => break,
                    }
                }
                _ = ping_interval.tick() => {
                    match tokio::time::timeout(
                        std::time::Duration::from_secs(10),
                        ws_tx.send(Message::Ping(vec![].into())),
                    ).await {
                        Ok(Ok(())) => {}
                        _ => {
                            eprintln!("[relay] Ping write failed/timeout");
                            break;
                        }
                    }
                }
            }
        }
        eprintln!("[relay] Write task exited for a peer");
    });

    // Read from WebSocket, forward to the OTHER peer in the room.
    // Uses select! to also detect write_task death — if the write side is
    // stuck/dead, we should tear down the whole connection.
    let rooms_read = rooms.clone();
    let room_id_read = room_id.clone();
    let mut write_task = write_task; // make mutable for &mut in select!

    loop {
        let msg = tokio::select! {
            result = ws_rx.next() => {
                match result {
                    Some(Ok(m)) => m,
                    _ => {
                        eprintln!("[relay] Peer {} stream ended", peer_id);
                        break;
                    }
                }
            }
            _ = &mut write_task => {
                eprintln!("[relay] Peer {} write task died, closing connection", peer_id);
                break;
            }
        };

        match &msg {
            Message::Close(_) => {
                eprintln!("[relay] Peer {} sent close", peer_id);
                break;
            }
            Message::Ping(d) => {
                // Respond with pong (WebSocket protocol requirement)
                let pong = Message::Pong(d.clone());
                let rooms_tmp = rooms_read.clone();
                let room_id_tmp = room_id_read.clone();
                // Send pong via the peer's own channel
                let map = rooms_tmp.lock().await;
                if let Some(room) = map.get(&room_id_tmp) {
                    if let Some(peer) = room.peers.iter().find(|p| p.id == peer_id) {
                        let _ = peer.tx.try_send(pong);
                    }
                }
                // Also update activity
                drop(map);
                let mut map = rooms_tmp.lock().await;
                if let Some(room) = map.get_mut(&room_id_tmp) {
                    if let Some(peer) = room.peers.iter_mut().find(|p| p.id == peer_id) {
                        peer.last_activity = tokio::time::Instant::now();
                    }
                }
                continue;
            }
            Message::Pong(_) => {
                // Update activity on pong — peer is alive and responding
                let mut map = rooms_read.lock().await;
                if let Some(room) = map.get_mut(&room_id_read) {
                    if let Some(peer) = room.peers.iter_mut().find(|p| p.id == peer_id) {
                        peer.last_activity = tokio::time::Instant::now();
                    }
                }
                continue;
            }
            _ => {}
        }

        // For text messages, validate auth token. Every text message after
        // the initial join (which is handled separately above) must carry
        // the token the relay handed back in the auth reply. There are no
        // "free pass" message types — including handshake/boot — so an
        // attacker who connects to a room cannot forge handshake material
        // on behalf of another peer slot.
        if let Message::Text(ref text) = msg {
            if text.len() > MAX_TEXT_FRAME_BYTES {
                eprintln!("[relay] Peer {} sent oversized frame ({}), dropping", peer_id, text.len());
                continue;
            }
            let text_str = text.to_string();
            match serde_json::from_str::<serde_json::Value>(&text_str) {
                Ok(val) => {
                    let msg_auth = val.get("auth").and_then(|v| v.as_str()).unwrap_or("");
                    let map = rooms_read.lock().await;
                    let token_ok = if let Some(room) = map.get(&room_id_read) {
                        if let Some(peer) = room.peers.iter().find(|p| p.id == peer_id) {
                            use subtle::ConstantTimeEq;
                            // Constant-time compare so the relay doesn't leak
                            // a timing oracle on the auth token.
                            peer.auth_token.as_bytes().ct_eq(msg_auth.as_bytes()).into()
                        } else {
                            false
                        }
                    } else {
                        false
                    };
                    drop(map);
                    if !token_ok {
                        eprintln!("[relay] Auth token mismatch from peer {}, dropping", peer_id);
                        continue;
                    }
                }
                Err(_) => {
                    eprintln!("[relay] Peer {} sent invalid JSON, dropping frame", peer_id);
                    continue;
                }
            }
        }

        // Update last_activity and forward to other peers
        let mut map = rooms_read.lock().await;
        if let Some(room) = map.get_mut(&room_id_read) {
            // Update sender's activity
            if let Some(peer) = room.peers.iter_mut().find(|p| p.id == peer_id) {
                peer.last_activity = tokio::time::Instant::now();
            }
            // Forward to other peers (strip auth field before forwarding)
            let forward_msg = if let Message::Text(ref text) = msg {
                let text_str = text.to_string();
                if let Ok(mut val) = serde_json::from_str::<serde_json::Value>(&text_str) {
                    if val.get("auth").is_some() {
                        val.as_object_mut().unwrap().remove("auth");
                        Message::Text(serde_json::to_string(&val).unwrap().into())
                    } else {
                        msg.clone()
                    }
                } else {
                    msg.clone()
                }
            } else {
                msg.clone()
            };
            for peer in &room.peers {
                if peer.id != peer_id {
                    let _ = peer.tx.try_send(forward_msg.clone());
                }
            }
        }
    }

    // Cleanup: remove this peer and notify remaining peers
    eprintln!("[relay] Peer {} disconnected, cleaning up", peer_id);
    write_task.abort();
    let _write_task = write_task;
    {
        let mut map = rooms.lock().await;
        if let Some(room) = map.get_mut(&room_id) {
            room.peers.retain(|p| p.id != peer_id);

            // Notify remaining peers that this peer disconnected
            let disconnect_msg = serde_json::json!({"type": "peer_disconnect", "peer_id": peer_id});
            let disconnect_text = Message::Text(serde_json::to_string(&disconnect_msg).unwrap().into());
            for peer in &room.peers {
                let _ = peer.tx.try_send(disconnect_text.clone());
                eprintln!("[relay] Notified peer {} of disconnect", peer.id);
            }

            eprintln!("[relay] Room now has {} peer(s)", room.peers.len());
            if room.peers.is_empty() {
                map.remove(&room_id);
                eprintln!("[relay] Room removed");
            }
        }
    }
}
