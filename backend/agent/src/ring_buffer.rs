use std::collections::VecDeque;

use ktty_common::constants::RING_BUFFER_SIZE;

#[derive(Clone)]
pub struct Packet {
    pub seq: u64,
    pub msg_type: String,
    pub payload: Vec<u8>,
}

impl Packet {
    fn byte_size(&self) -> usize {
        self.msg_type.len() + self.payload.len() + 16 // overhead
    }
}

pub struct RingBuffer {
    buf: VecDeque<Packet>,
    max_bytes: usize,
    current_bytes: usize,
}

impl RingBuffer {
    pub fn new() -> Self {
        Self {
            buf: VecDeque::new(),
            max_bytes: RING_BUFFER_SIZE,
            current_bytes: 0,
        }
    }

    pub fn push(&mut self, packet: Packet) {
        self.current_bytes += packet.byte_size();
        self.buf.push_back(packet);

        // Evict oldest packets if over capacity
        while self.current_bytes > self.max_bytes && !self.buf.is_empty() {
            if let Some(old) = self.buf.pop_front() {
                self.current_bytes -= old.byte_size();
            }
        }
    }

    /// Get the oldest sequence number still in the buffer.
    pub fn oldest_seq(&self) -> Option<u64> {
        self.buf.front().map(|p| p.seq)
    }

    /// Retrieve packets since `last_seq` and detect any gaps.
    /// Returns (packets, Option<(dropped_start, dropped_end)>).
    pub fn packets_since(&self, last_seq: u64) -> (Vec<Packet>, Option<(u64, u64)>) {
        let dropped = if let Some(oldest) = self.oldest_seq() {
            if last_seq + 1 < oldest {
                Some((last_seq + 1, oldest - 1))
            } else {
                None
            }
        } else {
            None
        };

        let packets: Vec<Packet> = self
            .buf
            .iter()
            .filter(|p| p.seq > last_seq)
            .cloned()
            .collect();

        (packets, dropped)
    }

    pub fn clear(&mut self) {
        self.buf.clear();
        self.current_bytes = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_push_and_retrieve() {
        let mut rb = RingBuffer::new();
        rb.push(Packet {
            seq: 1,
            msg_type: "pty".into(),
            payload: vec![0; 100],
        });
        rb.push(Packet {
            seq: 2,
            msg_type: "pty".into(),
            payload: vec![0; 100],
        });

        let (pkts, dropped) = rb.packets_since(0);
        assert_eq!(pkts.len(), 2);
        assert!(dropped.is_none());
    }

    #[test]
    fn test_partial_replay() {
        let mut rb = RingBuffer::new();
        for i in 1..=5 {
            rb.push(Packet {
                seq: i,
                msg_type: "pty".into(),
                payload: vec![0; 10],
            });
        }

        let (pkts, dropped) = rb.packets_since(3);
        assert_eq!(pkts.len(), 2);
        assert_eq!(pkts[0].seq, 4);
        assert_eq!(pkts[1].seq, 5);
        assert!(dropped.is_none());
    }

    #[test]
    fn test_overflow_detection() {
        let mut rb = RingBuffer {
            buf: VecDeque::new(),
            max_bytes: 200,
            current_bytes: 0,
        };

        // Push packets that exceed 200 bytes
        for i in 1..=10 {
            rb.push(Packet {
                seq: i,
                msg_type: "pty".into(),
                payload: vec![0; 50],
            });
        }

        // Some early packets should be evicted
        let oldest = rb.oldest_seq().unwrap();
        assert!(oldest > 1);

        // Request replay from seq 0 — should detect gap
        let (pkts, dropped) = rb.packets_since(0);
        assert!(dropped.is_some());
        let (start, end) = dropped.unwrap();
        assert_eq!(start, 1);
        assert!(end >= 1);
        assert!(!pkts.is_empty());
    }

    #[test]
    fn test_clear() {
        let mut rb = RingBuffer::new();
        rb.push(Packet {
            seq: 1,
            msg_type: "pty".into(),
            payload: vec![0; 100],
        });
        rb.clear();
        assert!(rb.oldest_seq().is_none());
        assert_eq!(rb.current_bytes, 0);
    }
}
