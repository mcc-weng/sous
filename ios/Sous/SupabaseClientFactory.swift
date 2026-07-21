// ios/Sous/SupabaseClientFactory.swift
import Foundation
import Supabase

enum SupabaseClientFactory {
    /// Shared between the main app and the share extension via a Keychain access
    /// group under the App Group `group.com.mikeweng.sous`, so a session created in
    /// one is usable in the other with no separate sign-in flow. `$(AppIdentifierPrefix)`
    /// in the .entitlements file resolves to the team ID at build time; runtime Swift
    /// code has to spell that resolved value out directly, since string interpolation
    /// doesn't happen in entitlements-adjacent build variables.
    static func make() -> SupabaseClient {
        SupabaseClient(
            supabaseURL: Config.supabaseURL,
            supabaseKey: Config.supabaseAnonKey,
            options: SupabaseClientOptions(
                auth: .init(
                    storage: KeychainLocalStorage(accessGroup: "9D37X3YV25.com.mikeweng.sous.shared")
                )
            )
        )
    }
}
