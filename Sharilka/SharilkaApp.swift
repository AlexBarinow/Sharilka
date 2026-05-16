//
//  SharilkaApp.swift
//  Sharilka
//
//  App entry point. Simple SwiftUI lifecycle, no SwiftData.
//

import SwiftUI

@main
struct SharilkaApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
