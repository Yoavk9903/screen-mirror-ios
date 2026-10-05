import SwiftUI

struct ContentView: View {
    @StateObject private var discovery = TvDiscovery()
    @State private var selectedTv: DiscoveredTv?
    @StateObject private var session = MirrorSession()

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                if discovery.tvs.isEmpty {
                    ProgressView("מחפש טלוויזיות ברשת...")
                        .padding()
                } else {
                    List(discovery.tvs) { tv in
                        Button {
                            selectedTv = tv
                            session.connect(to: tv)
                        } label: {
                            HStack {
                                Image(systemName: "tv")
                                Text(tv.name)
                                Spacer()
                                if selectedTv?.id == tv.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }

                if selectedTv != nil {
                    VStack(spacing: 8) {
                        Text("לחץ על הכפתור כדי להתחיל לשדר את המסך")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        BroadcastPickerView()
                            .frame(width: 60, height: 60)
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Screen Mirror")
            .onAppear { discovery.start() }
            .onDisappear { discovery.stop() }
        }
    }
}
