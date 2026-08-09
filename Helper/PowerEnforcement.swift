import Foundation

/// The rule this app enforces: while a switch is on, its value stays in effect
/// no matter who else writes it.
///
/// Authority is scoped to the switches the user actually turned on. A setting
/// whose switch is off belongs to the user — another app changing it is not
/// drift, it is none of our business. Enforcing those too would mean fighting
/// the user's own `pmset` over values they never asked us to hold.
enum PowerEnforcement {
    /// The settings that must be written for every active switch to be in
    /// effect, or nil when the machine already satisfies all of them.
    ///
    /// Returning nil matters: the enforcement loop runs often, and a write on
    /// every pass would churn the power management preferences for nothing.
    static func correction(for desired: PowerConfig, given current: PowerSettings) -> PowerSettings? {
        var wanted = current

        if desired.keepAwake { wanted.sleepMinutes = 0 }
        if desired.keepDisplayOn { wanted.displaySleepMinutes = 0 }
        if desired.stayAwakeWithLidClosed { wanted.disableSleep = true }

        return wanted == current ? nil : wanted
    }
}
