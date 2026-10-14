//
//  systemInfoApp.swift
//  systemInfo
//
//  Created by Daniel Ng Zheng Hui on 12/9/25.
//

import SwiftUI

@main
struct systemInfoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
				.onAppear { AppUpdates.shared.start() }
        }
        .defaultSize(width: 1240, height: 840)
		.commands { UpdateCommands() }
    }
}
