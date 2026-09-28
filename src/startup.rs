//! Process startup: the work `waterui_init` used to do, minus the FFI.
//!
//! Runs once, on the main thread, before the environment exists: ignore
//! `SIGPIPE`, attach the inspector when the environment asks for one, route
//! panics and records through `tracing`, install the global and the
//! main-queue local executors, then start the system-locale listener (its
//! mailbox pump needs the executor that was just installed).

use alloc::boxed::Box;

use waterui::inspector::InspectorRuntime;

/// The environment variable a launcher sets to name the level the application
/// logs at — `water run --logs <level>` writes it.
const LOG_LEVEL_ENV: &str = "WATERUI_LOG";

/// One-time process startup. Returns the inspector runtime when the
/// environment asked for one, for [`crate::entry`] to install.
pub fn initialize() -> Option<InspectorRuntime> {
    ignore_sigpipe();
    let inspector = waterui::inspector::maybe_init_from_env("apple");

    std::panic::set_hook(Box::new(|info| {
        tracing_panic::panic_hook(info);
    }));
    init_tracing(
        inspector
            .as_ref()
            .map(waterui::inspector::InspectorRuntime::tracing_layer),
    );

    executor_core::init_global_executor(native_executor::NativeExecutor::new());
    let main_executor = native_executor::NativeMainExecutor::new()
        .expect("waterui_apple_main runs on the platform main thread");
    executor_core::init_local_executor(waterui::task::monitored_local_executor_with_probes(
        main_executor,
        display_refresh_rate(),
        inspector
            .as_ref()
            .map(waterui::inspector::InspectorRuntime::runtime_probe),
    ));

    // The listener's mailbox pump needs the executor installed above.
    waterui_locale::start_system_locale_listener();

    inspector
}

/// Rust's own `lang_start` ignores `SIGPIPE`; a cdylib loaded by a foreign
/// main never runs it, so a process that pipes this output and exits first
/// would kill it. A failed write must surface as `EPIPE`.
fn ignore_sigpipe() {
    // SAFETY: `signal` only swaps the process-wide SIGPIPE disposition for
    // `SIG_IGN`; no handler runs Rust code, and this runs once at startup.
    unsafe {
        let previous = libc::signal(libc::SIGPIPE, libc::SIG_IGN);
        assert_ne!(
            previous,
            libc::SIG_ERR,
            "libc::signal(SIGPIPE, SIG_IGN) failed"
        );
    }
}

/// The refresh rate of the displays this host drives, for the executor's
/// frame budget.
fn display_refresh_rate() -> waterui::task::RefreshRate {
    use core::num::NonZeroU32;
    use waterui::task::RefreshRate;

    match waterkit_screen::max_refresh_rate() {
        Ok(rate) => {
            // `waterkit_screen::RefreshRate` is bounded to `1.0..=480.0` Hz,
            // so the millihertz value is nonzero and fits a `u32`.
            #[expect(
                clippy::cast_possible_truncation,
                clippy::cast_sign_loss,
                reason = "the source range is 1.0..=480.0 Hz"
            )]
            let millihertz = (f64::from(rate.get()) * 1000.0).round() as u32;
            RefreshRate::from_millihertz(
                NonZeroU32::new(millihertz).expect("a refresh rate of at least 1 Hz"),
            )
        }
        // Metadata the platform does not expose is not a fault of the app:
        // the budget only scales stall diagnostics, so it takes the nominal
        // rate.
        Err(error) => {
            tracing::info!(
                target: "waterui::runtime_guard",
                ?error,
                "display refresh rate is unavailable; budgeting frames at the nominal rate"
            );
            RefreshRate::HEADLESS
        }
    }
}

/// The `tracing` filter this process runs with: `RUST_LOG` wins outright,
/// otherwise `WATERUI_LOG` names the level and the graphics stack stays at
/// `error`.
fn env_filter() -> tracing_subscriber::EnvFilter {
    use tracing_subscriber::EnvFilter;

    if let Ok(filter) = EnvFilter::try_from_default_env() {
        return filter;
    }
    let level = std::env::var(LOG_LEVEL_ENV).unwrap_or_else(|_| String::from("error"));
    EnvFilter::try_new(format!(
        "{level},wgpu_core=error,wgpu_hal=error,naga=error,metal=error"
    ))
    .unwrap_or_else(|error| panic!("{LOG_LEVEL_ENV}={level:?} is not a tracing level: {error}"))
}

/// Sends `tracing` records to `os_log`, plus stderr when `WATERUI_LOG` asked
/// for a level — a physical iOS device's unified log is unreachable from the
/// host, and `devicectl --console` only carries stderr.
fn init_tracing(inspector: Option<waterui::inspector::InspectorLayer>) {
    use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

    let console_layer = std::env::var_os(LOG_LEVEL_ENV).map(|_| {
        tracing_subscriber::fmt::layer()
            .with_writer(std::io::stderr)
            .without_time()
    });
    tracing_subscriber::registry()
        .with(env_filter())
        .with(tracing_oslog::OsLogger::new("dev.waterui", "default"))
        .with(console_layer)
        .with(inspector)
        .init();
}
