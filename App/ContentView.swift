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
                        Text("לחץ על הכפתור הכחול כדי להתחיל לשדר את המסך")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        BroadcastPickerView()
                        Text("טיפ: כבוי המסך עוצר את השידור. מומלץ להגדיר בהגדרות > תצוגה > נעילה אוטומטית: אף פעם.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        if !session.stats.isEmpty {
                            Text(session.stats)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Screen Mirror")
            .onAppear {
                discovery.start()
                UIApplication.shared.isIdleTimerDisabled = true
            }
            .onDisappear {
                discovery.stop()
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }
}
