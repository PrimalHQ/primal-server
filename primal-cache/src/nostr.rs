pub use std::sync::Arc;

pub use hex::FromHex;

pub use hex;

pub use std::str::FromStr;

pub use nostr_sdk::prelude::{PublicKey, JsonUtil};

pub use serde_json::Value;
pub use serde_json::json;

use std::fmt;
use sha2::{Sha256, Digest};
use serde::{Serialize, Deserialize};

#[derive(PartialEq, Eq, Hash, Clone)]
pub struct EventId(pub Vec<u8>);

#[derive(PartialEq, Eq, Hash, Clone)]
pub struct PubKeyId(pub Vec<u8>);

#[derive(PartialEq, Eq, Hash, Clone)]
pub struct Sig(pub Vec<u8>);

impl Default for EventId {
    fn default() -> Self {
        EventId(vec![0; 32])
    }
}
impl Default for PubKeyId {
    fn default() -> Self {
        PubKeyId(vec![0; 32])
    }
}
impl Default for Sig {
    fn default() -> Self {
        Sig(vec![0; 64])
    }
}

macro_rules! impl_traits {
    ($($name:ident),+) => {
        $(
            impl serde::Serialize for $name {
                fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
                where
                    S: serde::Serializer,
                {
                    let hex = hex::encode(&self.0);
                    serializer.serialize_str(&hex)
                }
            }
            impl<'de> serde::Deserialize<'de> for $name {
                fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
                where
                    D: serde::Deserializer<'de>,
                {
                    let hex: String = serde::Deserialize::deserialize(deserializer)?;
                    let bytes = hex::decode(&hex).map_err(serde::de::Error::custom)?;
                    Ok($name(bytes))
                }
            }
            impl fmt::Debug for $name {
                fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                    let hex = hex::encode(&self.0);
                    write!(f, "\"{hex}\"")
                }
            }
            impl fmt::Display for $name {
                fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                    let hex = hex::encode(&self.0);
                    write!(f, "{hex}")
                }
            }
            impl $name {
                pub fn from_hex(hex: &str) -> Result<Self, anyhow::Error> {
                    let bytes = Vec::from_hex(hex)?;
                    Ok($name(bytes))
                }
                pub fn to_hex(&self) -> String {
                    hex::encode(&self.0)
                }
            }
            impl From<Vec<u8>> for $name {
                fn from(v: Vec<u8>) -> Self {
                    $name(v)
                }
            }
        )*
    };
}

impl_traits!(EventId, PubKeyId, Sig);

#[derive(PartialEq, Eq, Serialize, Deserialize, Debug, Hash, Clone)]
pub struct EventAddr {
    pub kind: i64,
    pub pubkey: PubKeyId,
    pub identifier: String,
}

impl EventAddr {
    pub fn new(kind: i64, pubkey: PubKeyId, identifier: String) -> Self {
        EventAddr { kind, pubkey, identifier }
    }
}

impl fmt::Display for EventAddr {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}:{}:{}", self.kind, hex::encode(&self.pubkey.0), self.identifier)
    }
}

#[derive(PartialEq, Eq, Hash, Clone, Debug)]
pub enum EventReference {
    EventId(EventId),
    EventAddr(EventAddr),
}

#[derive(Debug, Clone, Hash, PartialEq, Eq)]
pub enum Tag {
    EventId(EventId, Vec<String>),
    PubKeyId(PubKeyId, Vec<String>),
    EventAddr(EventAddr, Vec<String>),
    Any(Vec<String>),
}

impl<'de> Deserialize<'de> for Tag {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let tag_data = Value::deserialize(deserializer)?
            .as_array()
            .ok_or_else(|| serde::de::Error::custom("Expected an array for Tag"))?
            .iter()
            .filter_map(|v| v.as_str())
            .map(|s| s.to_string())
            .collect::<Vec<_>>();
        match tag_data[0].as_str() {
            "e" if tag_data.len() >= 2 => {
                if let Ok(eid) = EventId::from_hex(&tag_data[1]) {
                    return Ok(Tag::EventId(eid, tag_data[2..].to_vec()))
                }
            }
            "p" if tag_data.len() >= 2 => {
                if let Ok(pk) = PubKeyId::from_hex(&tag_data[1]) {
                    return Ok(Tag::PubKeyId(pk, tag_data[2..].to_vec()))
                }
            }
            "a" if tag_data.len() >= 2 => {
                let parts = tag_data[1].split(':').collect::<Vec<_>>();
                if parts.len() == 3 {
                    if let (Ok(kind), Ok(pubkey)) = (parts[0].parse::<i64>(), PubKeyId::from_hex(parts[1])) {
                        return Ok(Tag::EventAddr(EventAddr {
                            kind, pubkey, identifier: parts[2].to_string(),
                        }, tag_data[2..].to_vec()));
                    }
                }
            }
            _ => return Ok(Tag::Any(tag_data)),
        }

        Err(serde::de::Error::custom("Invalid tag format"))
    }
}

impl Serialize for Tag {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        fn tag_to_value(v: &Vec<String>, rest: &Vec<String>) -> Value {
            let mut a = v.clone();
            a.extend(rest.iter().map(|s| s.to_string()));
            json!(a)
        }
        let sv = match self {
            Tag::EventId(event_id, rest) => tag_to_value(&vec!["e".to_string(), hex::encode(event_id)], rest),
            Tag::PubKeyId(pubkey, rest) => tag_to_value(&vec!["p".to_string(), hex::encode(pubkey)], rest),
            Tag::EventAddr(addr, rest) =>  tag_to_value(&vec!["a".to_string(), format!("{}:{}:{}", addr.kind, hex::encode(&addr.pubkey), addr.identifier)], rest),
            Tag::Any(rest) => tag_to_value(&vec![], rest),
        };
        sv.serialize(serializer)
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct Event {
    pub id: EventId,
    pub pubkey: PubKeyId,
    pub created_at: i64,
    pub kind: i64,
    pub tags: Vec<Tag>,
    pub content: String,
    pub sig: Sig,
}

pub fn parse_tags(tags: &Value) -> Result<Vec<Tag>, anyhow::Error> {
    let mut result = Vec::new();
    if let Some(arr) = tags.as_array() {
        for tag in arr {
            if let Some(tag_arr) = tag.as_array() {
                if !tag_arr.is_empty() {
                    let tag_data = tag_arr.iter()
                        .filter_map(|v| v.as_str())
                        .map(|s| s.to_string())
                        .collect::<Vec<_>>();
                    match tag_data[0].as_str() {
                        "e" if tag_data.len() >= 2 => {
                            if let Ok(eid) = EventId::from_hex(&tag_data[1]) {
                                result.push(Tag::EventId(eid, tag_data[2..].to_vec()));
                            }
                        }
                        "p" if tag_data.len() >= 2 => {
                            if let Ok(pk) = PubKeyId::from_hex(&tag_data[1]) {
                                result.push(Tag::PubKeyId(pk, tag_data[2..].to_vec()));
                            }
                        }
                        "a" if tag_data.len() >= 2 => {
                            let parts = tag_data[1].split(':').collect::<Vec<_>>();
                            if parts.len() == 3 {
                                if let (Ok(kind), Ok(pubkey)) = (parts[0].parse::<i64>(), PubKeyId::from_hex(parts[1])) {
                                    result.push(Tag::EventAddr(EventAddr {
                                        kind, pubkey, identifier: parts[2].to_string(),
                                    }, tag_data[2..].to_vec()));
                                }
                            }
                        }
                        _ => result.push(Tag::Any(tag_data)),
                    }
                }
            }
        }
    }
    Ok(result)
}

pub const TEXT_NOTE: i64 = 1;
pub const REPOST: i64 = 6;
pub const REACTION: i64 = 7;
pub const ZAP_RECEIPT: i64 = 9735;
pub const LONG_FORM_CONTENT: i64 = 30023;
pub const BOOKMARKS: i64 = 10003;
pub const FOLLOW_LIST: i64 = 39089;
pub const LIVE_EVENT: i64 = 30311;

pub const LIVE_EVENT_MUTELIST: i64 = 10555;

impl Tag {
    pub fn into_vec(self) -> Vec<String> {
        match self {
            Tag::EventId(eid, tag_data) => {
                let mut vec = vec![String::from("e"), hex::encode(&eid)];
                vec.extend(tag_data);
                vec
            }
            Tag::PubKeyId(pkid, tag_data) => {
                let mut vec = vec![String::from("p"), hex::encode(&pkid)];
                vec.extend(tag_data);
                vec
            }
            Tag::EventAddr(addr, tag_data) => {
                let mut vec = vec![String::from("a"), format!("{}:{}:{}", addr.kind, hex::encode(&addr.pubkey), addr.identifier)];
                vec.extend(tag_data);
                vec
            }
            Tag::Any(tag_data) => tag_data,
        }
    }
}

impl AsRef<[u8]> for EventId {
    fn as_ref(&self) -> &[u8] {
        &self.0
    }
}
impl AsRef<[u8]> for PubKeyId {
    fn as_ref(&self) -> &[u8] {
        &self.0
    }
}
impl AsRef<[u8]> for Sig {
    fn as_ref(&self) -> &[u8] {
        &self.0
    }
}

pub fn parse_parent_eid(e: &Event) -> Result<Option<EventReference>, anyhow::Error> {
    fn f(tags: &Vec<Tag>, cb: impl Fn(&Vec<String>) -> bool) -> Result<Option<EventReference>, anyhow::Error> {
        for tag in tags {
            match tag {
                Tag::EventId(eid, tag_data) if cb(tag_data) => {
                    return Ok(Some(EventReference::EventId(eid.clone())));
                }
                Tag::EventAddr(addr, tag_data) if cb(tag_data) => {
                    return Ok(Some(EventReference::EventAddr(addr.clone())));
                }
                _ => { },
            }
        }
        Ok(None)
    }

    let parent_eid = f(&e.tags, |tag_data| {
        tag_data.len() >= 2 && tag_data[1] == "reply"
    })?;
    if parent_eid.is_some() { return Ok(parent_eid); }
    
    let parent_eid = f(&e.tags, |tag_data| {
        tag_data.len() >= 2 && tag_data[1] == "root"
    })?;
    if parent_eid.is_some() { return Ok(parent_eid); }

    let parent_eid = f(&e.tags, |tag_data| {
        tag_data.len() >= 2 && (tag_data.len() < 2 || tag_data[1] != "mention")
    })?;
    if parent_eid.is_some() { return Ok(parent_eid); }

    Ok(parent_eid)
}

#[derive(Debug)]
pub struct ZapReceipt {
    pub sender_pubkey: PubKeyId,
    pub receiver_pubkey: PubKeyId,
    pub invoice: String,
    pub amount_msats: i64,
    pub event: Option<EventReference>,
}

pub fn parse_zap_receipt(e: &Event) -> Option<ZapReceipt> {
    if e.kind != ZAP_RECEIPT {
        return None;
    }

    let mut sender_pubkey: Option<PubKeyId> = None;
    let mut receiver_pubkey: Option<PubKeyId> = None;
    let mut invoice: Option<String> = None;
    let mut amount_msats: Option<i64> = None;
    let mut event: Option<EventReference> = None;

    for tag in &e.tags {
        match tag {
            Tag::PubKeyId(pk, _tag_data) => {
                receiver_pubkey = Some(pk.clone());
            }
            Tag::Any(tag_data) if tag_data.len() >= 2 && tag_data[0] == "P" => {
                if let Ok(pk) = PubKeyId::from_hex(&tag_data[1]) {
                    sender_pubkey = Some(pk);
                }
            }
            Tag::Any(tag_data) if tag_data.len() >= 2 && tag_data[0] == "bolt11" => {
                invoice = Some(tag_data[1].clone());
                let signed_invoice = tag_data[1].parse::<lightning_invoice::SignedRawBolt11Invoice>();
                amount_msats = signed_invoice.ok().and_then(|i| i.amount_pico_btc()).map(|v| v as i64 / 10);
            }
            Tag::Any(tag_data) if tag_data.len() >= 2 && tag_data[0] == "description" => {
                if let Ok(json) = serde_json::from_str::<Value>(&tag_data[1]) {
                    if let Some(pubkey_str) = json.get("pubkey").and_then(|v| v.as_str()) {
                        if let Ok(pk) = PubKeyId::from_hex(pubkey_str) {
                            sender_pubkey = Some(pk);
                        }
                    }
                }
            }
            Tag::EventId(eid, _) => {
                event = Some(EventReference::EventId(eid.clone()));
            }
            Tag::EventAddr(eaddr, _) => {
                event = Some(EventReference::EventAddr(eaddr.clone()));
            }
            _ => {}
        }
    }

    if let (Some(sender_pubkey), Some(receiver_pubkey), Some(invoice), Some(amount_msats)) = (sender_pubkey, receiver_pubkey, invoice, amount_msats) {
        Some(ZapReceipt { sender_pubkey, receiver_pubkey, invoice, amount_msats, event })
    } else {
        None
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum LiveEventStatus {
    Live,
    Ended,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum LiveEventParticipantType {
    Host,
    Unknown,
}

#[derive(Debug, Clone)]
pub struct LiveEvent {
    pub kind: i64,
    pub pubkey: PubKeyId,
    pub identifier: String,
    pub status: LiveEventStatus,
    pub participants: Vec<(PubKeyId, LiveEventParticipantType)>,
    pub e: Event,
}

/// Verifies participant proof for event participation
/// Proof should be a signed SHA256 of the complete a Tag (kind:pubkey:dTag) by participant's private key
pub fn verify_participant_proof(participant_pubkey: &PubKeyId, proof_hex: &str, event_kind: i64, event_pubkey: &PubKeyId, identifier: &str) -> Result<bool, anyhow::Error> {
    // Decode the hex proof
    let proof_bytes = hex::decode(proof_hex).map_err(|_| anyhow::anyhow!("Invalid hex proof"))?;
    if proof_bytes.len() != 64 {
        return Err(anyhow::anyhow!("Proof must be 64 bytes"));
    }
    
    // Create the expected message: "kind:pubkey:dTag"
    let event_pubkey_hex = hex::encode(&event_pubkey.0);
    let message = format!("{}:{}:{}", event_kind, event_pubkey_hex, identifier);
    
    // Hash the message
    let mut hasher = Sha256::new();
    hasher.update(message.as_bytes());
    let message_hash = hasher.finalize();
    
    // Use Schnorr signatures as used in Nostr
    use nostr_sdk::secp256k1::{schnorr::Signature as SchnorrSignature, XOnlyPublicKey, Message, Secp256k1};
    
    let secp = Secp256k1::verification_only();
    
    // Convert participant public key to x-only format (32-byte Schnorr public key)
    let x_only_pubkey = XOnlyPublicKey::from_slice(&participant_pubkey.0)
        .map_err(|_| anyhow::anyhow!("Invalid participant public key format"))?;
    
    // Create message from hash
    let message = Message::from_digest_slice(&message_hash)
        .map_err(|_| anyhow::anyhow!("Invalid message hash"))?;
    
    // Convert proof to Schnorr signature format
    let schnorr_sig = SchnorrSignature::from_slice(&proof_bytes)
        .map_err(|_| anyhow::anyhow!("Invalid Schnorr signature format"))?;
    
    // Verify the Schnorr signature
    Ok(secp.verify_schnorr(&schnorr_sig, &message, &x_only_pubkey).is_ok())
}

pub fn parse_live_event(e: &Event) -> Option<LiveEvent> {
    if e.kind != LIVE_EVENT {
        return None;
    }
    let mut identifier = None;
    let mut status = LiveEventStatus::Unknown;
    let mut participant_candidates: Vec<(PubKeyId, LiveEventParticipantType, Option<String>)> = Vec::new();
    
    // First pass: collect all tags
    for t in &e.tags {
        match t {
            Tag::PubKeyId(pk, rest) => {
                let participant_type = if rest.len() >= 2 && rest[1].to_lowercase() == "host" { 
                    LiveEventParticipantType::Host 
                } else { 
                    LiveEventParticipantType::Unknown 
                };
                
                let proof = if rest.len() >= 3 { 
                    Some(rest[2].clone()) 
                } else { 
                    None 
                };
                
                participant_candidates.push((pk.clone(), participant_type, proof));
            }
            Tag::Any(fields) if fields.len() >= 2 => {
                match fields[0].as_str() {
                    "d" => {
                        identifier = Some(fields[1].clone());
                    },
                    "status" => {
                        match fields[1].as_str() {
                            "live" => status = LiveEventStatus::Live,
                            "ended" => status = LiveEventStatus::Ended,
                            _ => { },
                        }
                    },
                    _ => {}
                }
            }
            _ => {}
        }
    }
    
    // Second pass: verify participants with proofs if we have an identifier
    let mut participants = Vec::new();
    if let Some(ref identifier) = identifier {
        for (pk, participant_type, proof_opt) in participant_candidates {
            match proof_opt {
                Some(proof_hex) => {
                    // Proof provided - verify it
                    match verify_participant_proof(&pk, &proof_hex, e.kind, &e.pubkey, identifier) {
                        Ok(true) => {
                            eprintln!("Verified proof for participant {}", hex::encode(&pk.0));
                            participants.push((pk, participant_type));
                        },
                        Ok(false) => {
                            eprintln!("Invalid proof for participant {}", hex::encode(&pk.0));
                        },
                        Err(err) => {
                            eprintln!("Error verifying proof for participant {}: {}", hex::encode(&pk.0), err);
                        }
                    }
                },
                None => {
                    // No proof provided - allow for backward compatibility but log warning
                    eprintln!("No proof provided for participant {}", hex::encode(&pk.0));
                    participants.push((pk, participant_type));
                }
            }
        }
        
        Some(LiveEvent {
            kind: e.kind,
            pubkey: e.pubkey.clone(),
            identifier: identifier.clone(),
            status,
            participants,
            e: e.clone(),
        })
    } else {
        None
    }
}

