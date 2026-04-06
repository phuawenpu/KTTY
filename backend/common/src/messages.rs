use serde::{Deserialize, Serialize};

// --- Unencrypted routing ---

#[derive(Debug, Serialize, Deserialize)]
pub struct JoinMessage {
    pub action: String,
    pub room_id: String,
}

impl JoinMessage {
    pub fn new(room_id: String) -> Self {
        Self {
            action: "join".to_string(),
            room_id,
        }
    }
}

// --- Handshake ---

#[derive(Debug, Serialize, Deserialize)]
pub struct HandshakeOffer {
    pub r#type: String,
    pub mlkem_pub_key: String,
}

impl HandshakeOffer {
    pub fn new(pub_key_b64: String) -> Self {
        Self {
            r#type: "handshake".to_string(),
            mlkem_pub_key: pub_key_b64,
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct HandshakeReply {
    pub r#type: String,
    pub mlkem_ciphertext: String,
}

// --- Encrypted envelope ---

#[derive(Debug, Serialize, Deserialize)]
pub struct EncryptedEnvelope {
    pub seq: u64,
    pub r#type: String,
    pub payload: String,
}

impl EncryptedEnvelope {
    pub fn new(seq: u64, msg_type: &str, payload_b64: String) -> Self {
        Self {
            seq,
            r#type: msg_type.to_string(),
            payload: payload_b64,
        }
    }
}

// --- Boot signal (unencrypted) ---

#[derive(Debug, Serialize, Deserialize)]
pub struct BootSignal {
    pub r#type: String,
}

impl BootSignal {
    pub fn new() -> Self {
        Self {
            r#type: "boot".to_string(),
        }
    }
}

// --- Decrypted payload types ---

#[derive(Debug, Serialize, Deserialize)]
pub struct ResizePayload {
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SyncReqPayload {
    pub last_seq: u64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SyncWarnPayload {
    pub dropped_start: u64,
    pub dropped_end: u64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SysKillPayload {
    pub signal: String,
}

// --- Generic incoming message parser ---

/// Attempts to determine message type from raw JSON.
#[derive(Debug, Deserialize)]
pub struct RawMessage {
    pub action: Option<String>,
    pub r#type: Option<String>,
    pub room_id: Option<String>,
    pub mlkem_pub_key: Option<String>,
    pub mlkem_ciphertext: Option<String>,
    pub seq: Option<u64>,
    pub payload: Option<String>,
    pub hmac: Option<String>,
}

impl RawMessage {
    pub fn is_join(&self) -> bool {
        self.action.as_deref() == Some("join")
    }

    pub fn is_handshake(&self) -> bool {
        self.r#type.as_deref() == Some("handshake")
    }

    pub fn is_boot(&self) -> bool {
        self.r#type.as_deref() == Some("boot")
    }
}
