//
//  SystemInfoWidgetBundle.swift
//  SystemInfoWidget
//
//  Created by Daniel Ng Zheng Hui on 12/9/25.
//

import WidgetKit
import SwiftUI

@main
struct SystemInfoWidgetBundle: WidgetBundle {
    var body: some Widget {
        SystemInfoWidget()
        SystemInfoWidgetControl()
    }
}
