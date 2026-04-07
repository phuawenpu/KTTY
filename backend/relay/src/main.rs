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

    fn add_peer(&mut self, tx: Tx) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        self.peers.push(Peer { id, tx });
        id
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

    let app = Router::new()
        .route("/ws", get(ws_handler))
        .route("/health", get(move || health_handler(rooms_health.clone())))
        .with_state(rooms);

    let addr = format!("0.0.0.0:{port}");
    println!("KTTY Relay listening on ws://{addr}/ws");

    // Spawn periodic stale room cleanup
    let rooms_cleanup = app.clone();
    tokio::spawn(async move {
        let _ = rooms_cleanup; // keep reference
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(60)).await;
            eprintln!("[relay] Periodic health check running");
        }
    });

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

    // Register in room and get our peer ID
    let peer_id;
    let peer_count;
    {
        let mut map = rooms.lock().await;
        let room = map.entry(room_id.clone()).or_insert_with(Room::new);

        // Clean up stale peers — try sending a ping, evict if it fails
        room.peers.retain(|p| p.tx.send(Message::Ping(vec![].into())).is_ok());

        if room.peers.len() >= 2 {
            // Evict the oldest peer to make room
            eprintln!("[relay] Room full, evicting oldest peer");
            room.peers.remove(0);
        }

        peer_id = room.add_peer(tx);
        peer_count = room.peers.len();
    }
    eprintln!("[relay] Peer {} joined (now {} in room)", peer_id, peer_count);

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

    // Task: forward from channel to WebSocket sink + send periodic pings
    let write_task = tokio::spawn(async move {
        let mut ping_interval = tokio::time::interval(std::time::Duration::from_secs(15));
        ping_interval.tick().await; // skip immediate tick
        loop {
            tokio::select! {
                msg = rx.recv() => {
                    match msg {
                        Some(m) => {
                            if ws_tx.send(m).await.is_err() {
                                break;
                            }
                        }
                        None => break,
                    }
                }
                _ = ping_interval.tick() => {
                    if ws_tx.send(Message::Ping(vec![].into())).await.is_err() {
                        break;
                    }
                }
            }
        }
    });

    // Read from WebSocket, forward to the OTHER peer in the room
    let rooms_read = rooms.clone();
    let room_id_read = room_id.clone();

    loop {
        let read_timeout = tokio::time::sleep(std::time::Duration::from_secs(30));
        tokio::pin!(read_timeout);

        let msg = tokio::select! {
            msg = ws_rx.next() => msg,
            _ = &mut read_timeout => {
                eprintln!("[relay] Peer {} timed out (30s idle)", peer_id);
                break;
            }
        };

        let msg = match msg {
            Some(Ok(m)) => m,
            _ => {
                eprintln!("[relay] Peer {} stream ended", peer_id);
                break;
            }
        };

        match &msg {
            Message::Close(_) => {
                eprintln!("[relay] Peer {} sent close", peer_id);
                break;
            }
            Message::Ping(_) | Message::Pong(_) => continue,
            _ => {}
        }

        let map = rooms_read.lock().await;
        if let Some(room) = map.get(&room_id_read) {
            let targets = room.peers.iter().filter(|p| p.id != peer_id).count();
            eprintln!("[relay] Peer {} -> forwarding to {} peer(s)", peer_id, targets);
            for peer in &room.peers {
                if peer.id != peer_id {
                    let _ = peer.tx.send(msg.clone());
                }
            }
        }
    }

    // Cleanup: remove this peer from the room
    eprintln!("[relay] Peer {} read loop exited, cleaning up", peer_id);
    write_task.abort();
    {
        let mut map = rooms.lock().await;
        if let Some(room) = map.get_mut(&room_id) {
            room.peers.retain(|p| p.id != peer_id);
            eprintln!("[relay] Room now has {} peer(s)", room.peers.len());
            if room.peers.is_empty() {
                map.remove(&room_id);
                eprintln!("[relay] Room removed");
            }
        }
    }
}
