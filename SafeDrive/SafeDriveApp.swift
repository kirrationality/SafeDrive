//
//  SafeDriveApp.swift
//  SafeDrive

import SwiftUI

@main
struct SafeDriveApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.light) // --this keeps app background white even after sunset
        }
    }
}
