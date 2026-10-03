//! One import-free component invocation per disposable process. No WASI linker.
#[cfg(not(unix))]
compile_error!("This development host requires Unix resource and Port semantics");
use std::io::{self, Read, Write};
use std::time::Duration;

use sha2::{Digest, Sha256};
use wasmtime::component::types::ComponentItem;
use wasmtime::component::{Component, Linker};
use wasmtime::{Config, Engine, ResourceLimiter, Store, StoreLimits, StoreLimitsBuilder, Trap};

wasmtime::component::bindgen!({ path: "../wit", world: "profile" });

const MAX_COMPONENT: usize = 512 * 1024;
const MAX_REQUEST: usize = MAX_COMPONENT + 72;
const WORLD_EXPORT: &str = "wotex:home-profile/light-power@0.1.0";

fn retire(status: i32) -> ! {
    // Cancellation must not wait for C exit handlers or allocator cleanup.
    unsafe { libc::_exit(status) }
}

struct State {
    limits: StoreLimits,
    budget_hit: bool,
}

impl ResourceLimiter for State {
    fn memory_growing(
        &mut self,
        current: usize,
        desired: usize,
        maximum: Option<usize>,
    ) -> wasmtime::Result<bool> {
        let result = self.limits.memory_growing(current, desired, maximum);
        self.budget_hit |= !matches!(result, Ok(true));
        result
    }
    fn table_growing(
        &mut self,
        current: usize,
        desired: usize,
        maximum: Option<usize>,
    ) -> wasmtime::Result<bool> {
        let result = self.limits.table_growing(current, desired, maximum);
        self.budget_hit |= !matches!(result, Ok(true));
        result
    }
    fn instances(&self) -> usize {
        self.limits.instances()
    }
    fn tables(&self) -> usize {
        self.limits.tables()
    }
    fn memories(&self) -> usize {
        self.limits.memories()
    }
}

fn main() {
    // Covers parsing, compiler, lifting and cleanup, not just Wasm instructions.
    std::thread::spawn(|| {
        std::thread::sleep(Duration::from_secs(5));
        retire(124);
    });
    let response = if native_limits().is_err() {
        vec![1, 3, 6]
    } else {
        let request = read_request(&mut io::stdin().lock());
        match request {
            Ok(request) => {
                // Port closure must retire an executing or compiling process.
                std::thread::spawn(|| {
                    let mut extra = [0u8; 1];
                    let _ = io::stdin().read(&mut extra);
                    retire(125);
                });
                invoke(&request).unwrap_or_else(|code| vec![1, 3, code])
            }
            Err(_) => vec![1, 3, 0],
        }
    };
    let mut stdout = io::stdout().lock();
    if stdout
        .write_all(&(response.len() as u32).to_be_bytes())
        .is_err()
        || stdout.write_all(&response).is_err()
        || stdout.flush().is_err()
    {
        std::process::exit(1);
    }
}

fn read_request(reader: &mut impl Read) -> io::Result<Vec<u8>> {
    let mut prefix = [0; 4];
    reader.read_exact(&mut prefix)?;
    let size = u32::from_be_bytes(prefix) as usize;
    if !(70..=MAX_REQUEST).contains(&size) {
        return Err(io::ErrorKind::InvalidData.into());
    }
    let mut request = vec![0; size];
    reader.read_exact(&mut request)?;
    Ok(request)
}

fn invoke(request: &[u8]) -> Result<Vec<u8>, u8> {
    if request.len() < 70 || request[0] != 1 || request[1] > 1 {
        return Err(0);
    }
    let size = u32::from_be_bytes(request[66..70].try_into().map_err(|_| 0)?) as usize;
    if size == 0 || size > MAX_COMPONENT || request.len() < 70 + size {
        return Err(0);
    }
    let binary = &request[70..70 + size];
    let input = &request[70 + size..];
    if (request[1] == 0 && input.len() > 2)
        || (request[1] == 1 && (input.len() != 1 || input[0] > 1))
    {
        return Err(0);
    }
    if Sha256::digest(binary).as_slice() != &request[2..34] {
        return Err(1);
    }
    if Sha256::digest(include_bytes!("../../wit/profile.wit")).as_slice() != &request[34..66] {
        return Err(8);
    }
    // Binary-only entry point: never deserializes native code or accepts WAT.
    let mut config = Config::new();
    config
        .consume_fuel(true)
        .max_wasm_stack(512 * 1024)
        .memory_reservation(4 * 1024 * 1024)
        .memory_reservation_for_growth(0)
        .wasm_memory64(false)
        .wasm_relaxed_simd(false);
    let engine = Engine::new(&config).map_err(|_| 6)?;
    let component = Component::from_binary(&engine, binary).map_err(|_| 2)?;
    let ty = component.component_type();
    if ty.imports(&engine).next().is_some()
        || ty
            .exports(&engine)
            .map(|(name, _)| name)
            .collect::<Vec<_>>()
            != [WORLD_EXPORT]
    {
        return Err(3);
    }
    let Some(export) = ty.get_export(&engine, WORLD_EXPORT) else {
        return Err(3);
    };
    let ComponentItem::ComponentInstance(interface) = export.ty else {
        return Err(3);
    };
    let mut names = interface
        .exports(&engine)
        .map(|(name, _)| name)
        .collect::<Vec<_>>();
    names.sort_unstable();
    if names != ["decode-error", "decode-power", "encode-power"] {
        return Err(3);
    }
    use exports::wotex::home_profile::light_power::DecodeError;
    for (name, _) in interface.exports(&engine) {
        let item = interface.get_export(&engine, name).ok_or(3)?.ty;
        match (name, item) {
            ("decode-power", ComponentItem::ComponentFunc(function)) => {
                function
                    .typecheck::<(Vec<u8>,), (Result<bool, DecodeError>,)>(&ty.instance_type())
                    .map_err(|_| 3)?;
            }
            ("encode-power", ComponentItem::ComponentFunc(function)) => {
                function
                    .typecheck::<(bool,), (Vec<u8>,)>(&ty.instance_type())
                    .map_err(|_| 3)?;
            }
            ("decode-error", ComponentItem::Type(wasmtime::component::Type::Enum(value))) => {
                if value.names().collect::<Vec<_>>() != ["malformed", "unsupported"] {
                    return Err(3);
                }
            }
            _ => return Err(3),
        }
    }
    let limits = StoreLimitsBuilder::new()
        .memory_size(4 * 1024 * 1024)
        .memories(4)
        .tables(4)
        .table_elements(1024)
        .instances(16)
        .trap_on_grow_failure(true)
        .build();
    let mut store = Store::new(
        &engine,
        State {
            limits,
            budget_hit: false,
        },
    );
    store.limiter(|state| state);
    store.set_fuel(2_000_000).map_err(|_| 6)?;
    let linker = Linker::<State>::new(&engine);
    // Generated bindings type-check before any exported function is called.
    let pre = ProfilePre::new(linker.instantiate_pre(&component).map_err(|_| 3)?).map_err(|_| 3)?;
    let profile = pre.instantiate(&mut store).map_err(|error| {
        if store.data().budget_hit {
            7
        } else {
            classify(error)
        }
    })?;
    let api = profile.wotex_home_profile_light_power();
    if request[1] == 0 {
        match api.call_decode_power(&mut store, input).map_err(|error| {
            if store.data().budget_hit {
                7
            } else {
                classify(error)
            }
        })? {
            Ok(power) => Ok(vec![1, 0, u8::from(power)]),
            Err(exports::wotex::home_profile::light_power::DecodeError::Malformed) => {
                Ok(vec![1, 1, 0])
            }
            Err(exports::wotex::home_profile::light_power::DecodeError::Unsupported) => {
                Ok(vec![1, 1, 1])
            }
        }
    } else {
        let power = input[0] == 1;
        let payload = api.call_encode_power(&mut store, power).map_err(|error| {
            if store.data().budget_hit {
                7
            } else {
                classify(error)
            }
        })?;
        let expected = if power {
            [255, 255, 0, 0, 0, 0]
        } else {
            [0; 6]
        };
        if payload != expected {
            return Err(5);
        }
        let mut response = vec![1, 2];
        response.extend_from_slice(&payload);
        Ok(response)
    }
}

fn classify(error: wasmtime::Error) -> u8 {
    match error.downcast_ref::<Trap>() {
        Some(Trap::OutOfFuel | Trap::StackOverflow | Trap::AllocationTooLarge) => 7,
        Some(_) => 4,
        None => 4,
    }
}

fn native_limits() -> io::Result<()> {
    #[cfg(unix)]
    unsafe {
        for (resource, ceiling) in [
            (libc::RLIMIT_CORE, 0),
            (libc::RLIMIT_CPU, 3),
            (libc::RLIMIT_NOFILE, 32),
        ] {
            let limit = libc::rlimit {
                rlim_cur: ceiling,
                rlim_max: ceiling,
            };
            if libc::setrlimit(resource, &limit) != 0 {
                return Err(io::Error::last_os_error());
            }
        }
        #[cfg(target_os = "linux")]
        {
            let ceiling = 512 * 1024 * 1024;
            let limit = libc::rlimit {
                rlim_cur: ceiling,
                rlim_max: ceiling,
            };
            if libc::setrlimit(libc::RLIMIT_AS, &limit) != 0 {
                return Err(io::Error::last_os_error());
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn framing_rejects_unbounded_and_truncated_input() {
        assert!(read_request(&mut &u32::MAX.to_be_bytes()[..]).is_err());
        assert!(read_request(&mut &[0, 0, 0, 38, 1][..]).is_err());
    }

    #[test]
    fn request_hash_and_shape_are_checked_before_compilation() {
        assert_eq!(invoke(&[1; 70]), Err(0));
        let mut request = vec![1, 0];
        request.extend_from_slice(&[0; 32]);
        request.extend_from_slice(&Sha256::digest(include_bytes!("../../wit/profile.wit")));
        request.extend_from_slice(&1u32.to_be_bytes());
        request.push(0);
        assert_eq!(invoke(&request), Err(1));
        request[2..34].copy_from_slice(&Sha256::digest([0]));
        assert_eq!(invoke(&request), Err(2));
        request[34] ^= 1;
        assert_eq!(invoke(&request), Err(8));
    }

    #[test]
    fn unbound_imports_and_wrong_world_are_rejected() {
        for wat in ["(component (import \"ambient\" (func)))", "(component)"] {
            let binary = wat::parse_str(wat).unwrap();
            let mut request = vec![1, 0];
            request.extend_from_slice(&Sha256::digest(&binary));
            request.extend_from_slice(&Sha256::digest(include_bytes!("../../wit/profile.wit")));
            request.extend_from_slice(&(binary.len() as u32).to_be_bytes());
            request.extend_from_slice(&binary);
            assert_eq!(invoke(&request), Err(3));
        }
    }
}
