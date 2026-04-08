use axum::{
    Router,
    extract::{
        State,
        ws::{Message, WebSocket, WebSocketUpgrade},
    },
    response::IntoResponse,
    routing::get,
};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{mpsc, Mutex};

type Tx = mpsc::UnboundedSender<Message>;

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
        // Generate a simple auth token from id + timestamp (real security is in ML-KEM layer)
        let now_nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let auth_token = format!("{:016x}{:032x}", id, now_nanos);
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
                        && p.tx.send(Message::Ping(vec![].into())).is_ok();
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

async fn health_handler(rooms: RoomMap) -> impl IntoResponse {
    let map = rooms.lock().await;
    let room_count = map.len();
    let peer_count: usize = map.values().map(|r| r.peers.len()).sum();
    let body = format!(
        "{{\"status\":\"ok\",\"rooms\":{},\"peers\":{},\"uptime_check\":true}}",
        room_count, peer_count
    );
    (
        axum::http::StatusCode::OK,
        [("content-type", "application/json")],
        body,
    )
}

async fn ws_handler(
    ws: WebSocketUpgrade,
    State(rooms): State<RoomMap>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, rooms))
}

async fn handle_socket(socket: WebSocket, rooms: RoomMap) {
    use futures_util::{SinkExt, StreamExt};

    let (mut ws_tx, mut ws_rx) = socket.split();

    // First message must be a join
    let room_id = match ws_rx.next().await {
        Some(Ok(Message::Text(text))) => {
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

    eprintln!("[relay] Client joined room: {}...{}", &room_id[..8], &room_id[room_id.len()-8..]);

    // Create channel for this peer
    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();
    let tx_auth = tx.clone();

    // Register in room and get our peer ID + auth token
    let peer_id;
    let auth_token;
    let peer_count;
    {
        let mut map = rooms.lock().await;
        let room = map.entry(room_id.clone()).or_insert_with(Room::new);

        // Clean up stale peers — try sending a ping, evict if it fails
        room.peers.retain(|p| p.tx.send(Message::Ping(vec![].into())).is_ok());

        if room.peers.len() >= 2 {
            // Evict the least recently active peer (likely a stale connection)
            if let Some(idx) = room.peers.iter().enumerate()
                .min_by_key(|(_, p)| p.last_activity)
                .map(|(i, _)| i)
            {
                let evicted = &room.peers[idx];
                // Notify the evicted peer so it knows to reconnect
                let msg = serde_json::json!({"type": "peer_disconnect", "peer_id": evicted.id});
                let _ = evicted.tx.send(Message::Text(serde_json::to_string(&msg).unwrap().into()));
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
        let _ = tx_auth.send(auth_text);
    }

    // Notify existing peers that a new client joined by forwarding the join message
    {
        let join_msg = serde_json::json!({"action": "join", "room_id": room_id});
        let join_text = Message::Text(serde_json::to_string(&join_msg).unwrap().into());
        let map = rooms.lock().await;
        if let Some(room) = map.get(&room_id) {
            for peer in &room.peers {
                if peer.id != peer_id {
                    let _ = peer.tx.send(join_text.clone());
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
                        let _ = peer.tx.send(pong);
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

        // For text messages, validate auth token
        if let Message::Text(ref text) = msg {
            let text_str = text.to_string();
            if let Ok(val) = serde_json::from_str::<serde_json::Value>(&text_str) {
                // Join/action and handshake messages don't require auth
                let is_exempt = val.get("action").is_some()
                    || val.get("type").and_then(|v| v.as_str()) == Some("handshake")
                    || val.get("type").and_then(|v| v.as_str()) == Some("boot");
                if !is_exempt {
                    let msg_auth = val.get("auth").and_then(|v| v.as_str()).unwrap_or("");
                    let map = rooms_read.lock().await;
                    if let Some(room) = map.get(&room_id_read) {
                        if let Some(peer) = room.peers.iter().find(|p| p.id == peer_id) {
                            if peer.auth_token != msg_auth {
                                eprintln!("[relay] Auth token mismatch from peer {}, dropping", peer_id);
                                continue;
                            }
                        }
                    }
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
                    let _ = peer.tx.send(forward_msg.clone());
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
                let _ = peer.tx.send(disconnect_text.clone());
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
