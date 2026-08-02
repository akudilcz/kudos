//! The definition of the kernel's monotonic wall clock (pure; timer.millis is
//! this function applied to the live counters).
//!
//! INVARIANT: no single core's failure can stop the wall clock. Once the TSC is
//! calibrated the clock DERIVES from that free-running counter, which involves
//! no interrupt delivery at all — so no core that wedges with interrupts masked
//! (capturing the rotating IO-APIC tick, spec KRN-012) can freeze time
//! machine-wide, and every millisecond-denominated timeout keeps counting. The
//! PIT tick counter backs the clock only before calibration, when the machine
//! is a single core with PIC delivery on the BSP: no rotation exists yet, so
//! there is nothing to capture. A frozen tick after calibration therefore
//! stalls only tick DELIVERY (visible as `ticks=` freezing in the netdebug
//! heartbeat while the clock climbs), never time.
//!
//! At the calibration switchover the clock steps forward once, by the gap
//! between kudos' first instruction (the TSC anchor) and the PIT starting —
//! well under a second, and forward, so the clock stays monotonic.

/// Milliseconds since boot from the available clock sources: `tsc_ms` (the
/// TSC-derived reading, 0 meaning "not calibrated yet"), else the tick counter
/// at `tick_hz`, else 0 (no clock source has been set up at all).
pub fn ms(tsc_ms: u64, tick_count: u64, tick_hz: u32) u64 {
    if (tsc_ms != 0) return tsc_ms;
    if (tick_hz == 0) return 0;
    return tick_count * 1000 / tick_hz;
}
