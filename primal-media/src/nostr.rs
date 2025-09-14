use serde::{Deserialize, Serialize};

// Minimal stand-ins for Julia's Nostr types used in signatures.

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct PubKeyId(pub String); // hex string

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct EventId(#[serde(with = "crate::processing_graph::hex32")] pub [u8; 32]);

