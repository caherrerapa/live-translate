import SwiftUI

/// Connect Google Calendar: paste the OAuth client ID once, sign in, and each new session
/// takes the meeting happening now as its title and context.
struct CalendarSettingsView: View {
    @ObservedObject var calendar = GoogleCalendar.shared
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var meetingNow: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Google Calendar").font(.title2.weight(.semibold))
            Text("When you start a session, Live Translate looks up the meeting happening now. Its title names the session, and its attendees and agenda help the summary. Read-only; nothing is written to your calendar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let account = calendar.account {
                HStack {
                    Label(account, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Sign Out", role: .destructive) {
                        calendar.signOut()
                        meetingNow = nil
                    }
                }
                Button("Check the meeting now") {
                    Task {
                        let meeting = await calendar.currentMeeting()
                        meetingNow = meeting.map { "\($0.title) · \($0.attendees.count) attendees" } ?? "No meeting right now."
                    }
                }
                if let meetingNow {
                    Text(meetingNow).font(.callout)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("OAuth client ID").font(.headline)
                    TextField("123456-abc.apps.googleusercontent.com", text: $calendar.clientID)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Text("In Google Cloud Console: create a project, enable the Google Calendar API, set up the OAuth consent screen, then create an OAuth client ID of type iOS with bundle ID com.caherrerapa.LiveTranslateiOS (the same client ID works on the Mac). Paste its client ID here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Task {
                        do {
                            try await calendar.signIn()
                            message = nil
                        } catch {
                            message = error.localizedDescription
                        }
                    }
                } label: {
                    Label(calendar.working ? "Signing in…" : "Sign in with Google", systemImage: "calendar")
                }
                .disabled(calendar.working || calendar.clientID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        #if os(macOS)
        .frame(width: 520)
        #endif
    }
}
