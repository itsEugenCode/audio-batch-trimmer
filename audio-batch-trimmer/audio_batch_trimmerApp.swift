//
//  audio_batch_trimmerApp.swift
//  audio-batch-trimmer
//
//  Created by Eugen on 24.02.2026.
//

import SwiftUI

@main
struct AudioBatchTrimmerApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
                .frame(minWidth: 800, minHeight: 600)
        }
    }
}

// Пакетная обрезка МР3 по длительности фрагмента
