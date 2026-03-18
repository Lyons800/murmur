//
//  Item.swift
//  WhisprMacOS
//
//  Created by Oisin Lyons on 18/03/2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
