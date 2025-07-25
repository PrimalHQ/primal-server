pub use std::sync::Arc;

pub use hex::FromHex;

pub use hex;

pub use std::str::FromStr;

pub use nostr_sdk::prelude::{PublicKey, JsonUtil};

pub use serde_json::Value;
pub use serde_json::json;

use std::fmt;

use serde::Serialize;

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
            impl fmt::Debug for $name {
                fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                    let hex = hex::encode(&self.0);
                    write!(f, "\"{hex}\"")
                }
            }
            impl $name {
                pub fn from_hex(hex: &str) -> Result<Self, anyhow::Error> {
                    let bytes = Vec::from_hex(hex)?;
                    Ok($name(bytes))
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

#[derive(PartialEq, Eq, Serialize, Debug, Hash, Clone)]
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

#[derive(Debug, Serialize, Clone, Default)]
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
    pub amount_msats: i64,
    pub event: Option<EventReference>,
}

pub fn parse_zap_receipt(e: &Event) -> Option<ZapReceipt> {
    if e.kind != ZAP_RECEIPT {
        return None;
    }

    let mut sender_pubkey: Option<PubKeyId> = None;
    let mut receiver_pubkey: Option<PubKeyId> = None;
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

    if let (Some(sender_pubkey), Some(receiver_pubkey), Some(amount_msats)) = (sender_pubkey, receiver_pubkey, amount_msats) {
        Some(ZapReceipt { sender_pubkey, receiver_pubkey, amount_msats, event })
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

pub fn parse_live_event(e: &Event) -> Option<LiveEvent> {
    if e.kind != LIVE_EVENT {
        return None;
    }
    let mut identifier = None;
    let mut status = LiveEventStatus::Unknown;
    let mut participants = Vec::new();
    for t in &e.tags {
        match t {
            Tag::PubKeyId(pk, rest) => {
                participants.push((
                        pk.clone(), 
                        if rest.len() >= 2 && rest[1] == "host" { LiveEventParticipantType::Host } else { LiveEventParticipantType::Unknown }));
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
    if let Some(identifier) = identifier {
        Some(LiveEvent {
            kind: e.kind,
            pubkey: e.pubkey.clone(),
            identifier: identifier.clone(),
            status,
            participants,
            e: e.clone(),
        })
    } else {
        return None;
    }
}

