#[cfg(test)]
mod tests {
    use crate::nostr::*;
    use sha2::{Sha256, Digest};
    use nostr_sdk::secp256k1::{Secp256k1, SecretKey, Keypair, Message};
    use std::str::FromStr;

    #[test]
    fn test_proof_verification_valid() {
        let secp = Secp256k1::new();
        
        // Generate a test keypair for Schnorr signatures
        let secret_key = SecretKey::from_str("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855").unwrap();
        let key_pair = Keypair::from_secret_key(&secp, &secret_key);
        let (x_only_pubkey, _parity) = key_pair.x_only_public_key();
        let participant_pubkey = PubKeyId(x_only_pubkey.serialize().to_vec());
        
        // Create test event data
        let event_kind = 30311i64;
        let event_pubkey = PubKeyId(vec![0x01; 32]);
        let identifier = "test-event";
        
        // Create the message to sign: "kind:pubkey:dTag"
        let event_pubkey_hex = hex::encode(&event_pubkey.0);
        let message = format!("{}:{}:{}", event_kind, event_pubkey_hex, identifier);
        
        // Hash the message
        let mut hasher = Sha256::new();
        hasher.update(message.as_bytes());
        let message_hash = hasher.finalize();
        
        // Create Schnorr signature
        let message_obj = Message::from_digest_slice(&message_hash).unwrap();
        let signature = secp.sign_schnorr(&message_obj, &key_pair);
        let proof_hex = hex::encode(signature.as_ref());
        
        // Test verification
        let result = verify_participant_proof(&participant_pubkey, &proof_hex, event_kind, &event_pubkey, identifier);
        match &result {
            Ok(valid) => {
                println!("Verification succeeded: {}", valid);
                assert!(*valid);
            },
            Err(e) => {
                println!("Verification failed with error: {}", e);
                panic!("Verification should not fail");
            }
        }
    }
    
    #[test]
    fn test_proof_verification_invalid_signature() {
        let participant_pubkey = PubKeyId(vec![0x02; 32]);
        let event_kind = 30311i64;
        let event_pubkey = PubKeyId(vec![0x01; 32]);
        let identifier = "test-event";
        let invalid_proof = "gg".repeat(64); // Invalid hex characters
        
        let result = verify_participant_proof(&participant_pubkey, &invalid_proof, event_kind, &event_pubkey, identifier);
        assert!(result.is_err());
    }
    
    #[test]
    fn test_proof_verification_wrong_signature() {
        let secp = Secp256k1::new();
        
        // Generate two different keypairs for Schnorr
        let secret_key1 = SecretKey::from_str("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855").unwrap();
        let key_pair1 = Keypair::from_secret_key(&secp, &secret_key1);
        let (x_only_pubkey1, _parity1) = key_pair1.x_only_public_key();
        let participant_pubkey = PubKeyId(x_only_pubkey1.serialize().to_vec());
        
        let secret_key2 = SecretKey::from_str("d3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b866").unwrap();
        let key_pair2 = Keypair::from_secret_key(&secp, &secret_key2);
        
        // Create test event data
        let event_kind = 30311i64;
        let event_pubkey = PubKeyId(vec![0x01; 32]);
        let identifier = "test-event";
        
        // Create the message to sign: "kind:pubkey:dTag"
        let event_pubkey_hex = hex::encode(&event_pubkey.0);
        let message = format!("{}:{}:{}", event_kind, event_pubkey_hex, identifier);
        
        // Hash the message
        let mut hasher = Sha256::new();
        hasher.update(message.as_bytes());
        let message_hash = hasher.finalize();
        
        // Sign with wrong key
        let message_obj = Message::from_digest_slice(&message_hash).unwrap();
        let signature = secp.sign_schnorr(&message_obj, &key_pair2);
        let proof_hex = hex::encode(signature.as_ref());
        
        // Test verification (should fail because signature was made with wrong key)
        let result = verify_participant_proof(&participant_pubkey, &proof_hex, event_kind, &event_pubkey, identifier);
        assert!(result.is_ok());
        assert!(!result.unwrap()); // Should be false
    }
}
