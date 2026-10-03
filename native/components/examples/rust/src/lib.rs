//! Independent author example. Pure payload mapping; no device or host I/O.
wit_bindgen::generate!({ path: "../../wit", world: "profile" });

use exports::wotex::home_profile::light_power::{DecodeError, Guest};

struct Codec;

impl Guest for Codec {
    fn decode_power(payload: Vec<u8>) -> Result<bool, DecodeError> {
        match payload.as_slice() {
            [0, 0] => Ok(false),
            [255, 255] => Ok(true),
            [_, _] => Err(DecodeError::Unsupported),
            _ => Err(DecodeError::Malformed),
        }
    }

    fn encode_power(power: bool) -> Vec<u8> {
        let level: u16 = if power { u16::MAX } else { 0 };
        let mut bytes = level.to_le_bytes().to_vec();
        bytes.extend_from_slice(&0u32.to_le_bytes());
        bytes
    }
}

export!(Codec);
