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

    let app = Router::new()
        .route("/ws", get(ws_handler))
        .with_state(rooms);

    let addr = format!("0.0.0.0:{port}");
    println!("KTTY Relay listening on ws://{addr}/ws");

    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
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
        return;
    }

    // Create channel for this peer
    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();

    // Register in room and get our peer ID
    let peer_id;
    {
        let mut map = rooms.lock().await;
        let room = map.entry(room_id.clone()).or_insert_with(Room::new);

        if room.peers.len() >= 2 {
            return; // Room full
        }

        peer_id = room.add_peer(tx);
    }

    // Task: forward from channel to WebSocket sink
    let write_task = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if ws_tx.send(msg).await.is_err() {
                break;
            }
        }
    });

    // Read from WebSocket, forward to the OTHER peer in the room
    let rooms_read = rooms.clone();
    let room_id_read = room_id.clone();

    while let Some(Ok(msg)) = ws_rx.next().await {
        match &msg {
            Message::Close(_) => break,
            Message::Ping(_) | Message::Pong(_) => continue,
            _ => {}
        }

        let map = rooms_read.lock().await;
        if let Some(room) = map.get(&room_id_read) {
            for peer in &room.peers {
                if peer.id != peer_id {
                    let _ = peer.tx.send(msg.clone());
                }
            }
        }
    }

    // Cleanup: remove this peer from the room
    {
        let mut map = rooms.lock().await;
        if let Some(room) = map.get_mut(&room_id) {
            room.peers.retain(|p| p.id != peer_id);
            if room.peers.is_empty() {
                map.remove(&room_id);
            }
        }
    }

    write_task.abort();
}
