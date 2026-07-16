pub mod error;
pub mod model;
pub mod server;
pub mod store;

pub use server::{AppState, build_router, run};

pub const ENGINE_VERSION: &str = env!("KBASE_LANCE_ENGINE_VERSION");
pub const LANCEDB_VERSION: &str = "0.30.0";
pub const PROTOCOL_VERSION: u32 = 2;

#[cfg(test)]
mod tests {
    use super::ENGINE_VERSION;

    #[test]
    fn engine_version_matches_version_file() {
        assert_eq!(
            ENGINE_VERSION,
            include_str!("../VERSION").trim().strip_prefix('v').unwrap()
        );
    }
}
