import SwiftUI

/// Shown until the first family exists. The first phone creates the family (it needs a parent's
/// device key, which the Mac does not have); after that, invites come from this app.
struct OverviewGettingStartedSection: View {
    @Environment(ServerModel.self) private var model

    let status: ServerStatus

    var body: some View {
        Section("Getting Started") {
            if status.advertisedUrls.isEmpty {
                step(1, "Choose how phones reach this Mac: home Wi-Fi, Tailscale, or both.") {
                    Button("Open Connections") {
                        model.selectedPane = .connections
                    }
                }
            } else {
                step(1, "Phones can reach this Mac. The addresses are listed below.") {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Done")
                }
            }
            step(2, "On your iPhone, open Benito and choose Create a Family. It finds this Mac on home Wi-Fi, or you can type one of the addresses.") {
                EmptyView()
            }
            step(3, "Then invite your partner or a caregiver from People & Devices here, or from the app on your phone.") {
                EmptyView()
            }
        }
    }

    private func step(_ number: Int, _ text: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            trailing()
        }
        .accessibilityElement(children: .combine)
    }
}
