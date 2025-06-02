//
//  ContentView.swift
//  SampleApp
//
//  Created by Luiz Diniz Hammerli on 31/05/25.
//

import SwiftUI
import LHMetricExporter

struct ContentView: View {
    @State var value: String = ""
    let screenLoader = ScreenLoader(timerThreshold: 10)

    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Hello, world!")
            Text("\(value)")
        }.onAppear {
            for index in 0..<200 {
                screenLoader.start(name: "Test Screen-\(index)")
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                for index in 0..<200 {
                    screenLoader.stop(name: "Test Screen-\(index)")
                }

                value = "Valor Finalizado!"
            }
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
