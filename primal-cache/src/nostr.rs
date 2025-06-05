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

#[derive(Debug, Serialize, Clone, Hash, PartialEq, Eq)]
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

pub fn event_to_json(e: &Event) -> Value {
    json!({
        "id": hex::encode(&e.id),
        "pubkey": hex::encode(&e.pubkey),
        "created_at": e.created_at,
        "kind": e.kind,
        "tags": e.tags.iter()
            .map(|tag| tag.clone().into_vec())
            .collect::<Vec<_>>(),
        "content": e.content,
        "sig": hex::encode(&e.sig),
    })
}

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

