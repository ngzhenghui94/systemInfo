//
//  AppIntent.swift
//  SystemInfoWidget
//
//  Created by Daniel Ng Zheng Hui on 12/9/25.
//

import WidgetKit
import AppIntents

/// No configuration needed for now, but you can extend this later if you want options.
struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Mac System Info" }
    static var description: IntentDescription { "Shows basic system information." }
}
