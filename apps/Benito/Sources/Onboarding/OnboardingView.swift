import BenitoKit
import SwiftUI

extension View {
    /// First run: covers the app until this phone is signed in (new family, invite, or account).
    /// An overlay rather than a cover so invite links can still present their join sheet on top.
    func benitoOnboarding(model: AppModel) -> some View {
        modifier(OnboardingModifier(model: model))
    }
}

private struct OnboardingModifier: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.overlay {
            if model.didResolveLaunch, !model.isSignedIn {
                OnboardingView(model: model)
                    .transition(.opacity)
            }
        }
        .animation(.smooth, value: model.isSignedIn)
    }
}

struct OnboardingView: View {
    let model: AppModel
    @State private var path: [Step] = []

    enum Intent: Hashable { case startFamily, signIn }

    enum Step: Hashable {
        case join
        case server(Intent)
        case details(server: URL)
        case signIn
    }

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeStep(model: model, path: $path)
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .join:
                        JoinInstructionsStep(model: model)
                    case .server(let intent):
                        ServerStep(model: model, intent: intent, path: $path)
                    case .details(let server):
                        FamilyDetailsStep(model: model, server: server)
                    case .signIn:
                        PasswordSignInStep(model: model)
                    }
                }
        }
        .tint(DesignTokens.feed)
        .onAppear(perform: applyScreenshotStep)
    }

    /// `SIMCTL_CHILD_BENITO_ONBOARDING_STEP` = join | server | details | signin opens that step
    /// (screenshots only). `details` uses `SIMCTL_CHILD_BENITO_SERVER_URL` (default localhost:8080).
    private func applyScreenshotStep() {
        let env = ProcessInfo.processInfo.environment
        guard path.isEmpty, let step = env["BENITO_ONBOARDING_STEP"]?.lowercased() else { return }
        let server = env["BENITO_SERVER_URL"].flatMap(URL.init(string:)) ?? URL(string: "http://localhost:8080")!
        switch step {
        case "join": path = [.join]
        case "server": path = [.server(.startFamily)]
        case "details": path = [.server(.startFamily), .details(server: server)]
        case "signin": path = [.server(.signIn), .signIn]
        default: break
        }
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    let model: AppModel
    @Binding var path: [OnboardingView.Step]

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Image(systemName: "figure.and.child.holdinghands")
                        .font(.system(size: 64))
                        .foregroundStyle(DesignTokens.feed)
                        .padding(28)
                        .background(DesignTokens.feed.opacity(0.14), in: Circle())
                        .accessibilityHidden(true)
                    Text("Welcome to Benito")
                        .font(.largeTitle.bold())
                    Text("Feeds, sleep, and diapers, shared with everyone who cares for your baby. Your data stays on your own server.")
                        .font(.body)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 40)

                VStack(spacing: 12) {
                    ChoiceCard(
                        title: "Start a family",
                        detail: "Set up Benito for your baby. Invite others after.",
                        systemImage: "plus.circle.fill",
                        tint: DesignTokens.feed
                    ) { path.append(.server(.startFamily)) }

                    ChoiceCard(
                        title: "Join a family",
                        detail: "Someone invited you by Messages, AirDrop, or SharePlay.",
                        systemImage: "person.2.fill",
                        tint: DesignTokens.sleep
                    ) { path.append(.join) }

                    ChoiceCard(
                        title: "This iPhone only",
                        detail: "No server, no sharing. Coming soon.",
                        systemImage: "iphone",
                        tint: DesignTokens.textTertiary
                    ) {}
                    .disabled(true)
                    .opacity(0.55)
                }

                Button("I already have an account") { path.append(.server(.signIn)) }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
            .padding(DesignTokens.gutter)
            .readableContentWidth()
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(DesignTokens.bgCanvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct ChoiceCard: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 48, height: 48)
                    .background(tint.opacity(0.16), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(DesignTokens.textPrimary)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DesignTokens.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(DesignTokens.gutter)
            .frame(maxWidth: .infinity, minHeight: DesignTokens.thumbMinTall)
            .background(DesignTokens.bgCard, in: RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous))
        }
        .buttonStyle(BenitoBorderlessButtonStyle())
    }
}

// MARK: - Join

private struct JoinInstructionsStep: View {
    let model: AppModel
    @State private var pasteError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                StepHeader(
                    title: "Join a family",
                    detail: "No account or password needed. You just need an invite from someone in the family."
                )
                VStack(alignment: .leading, spacing: 16) {
                    NumberedLine(1, "On their iPhone: Account › Sharing › Invite to Family.")
                    NumberedLine(2, "They send it by Messages or AirDrop, start SharePlay, or show you the QR code.")
                    NumberedLine(3, "Tap the link (or scan the code with Camera) and type your name.")
                }
                .padding(DesignTokens.gutter)
                .background(DesignTokens.bgCard, in: RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Link didn't open the app?")
                        .font(.subheadline.weight(.semibold))
                    Text("Copy the whole message, then paste it here.")
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.textSecondary)
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in
                            if let link = strings.lazy.compactMap(FamilyInviteLink.init(text:)).first {
                                pasteError = nil
                                model.pendingJoinLink = link
                            } else {
                                pasteError = "That doesn't contain a Benito invite. Ask them to send it again."
                            }
                        }
                    }
                    .buttonBorderShape(.capsule)
                    .labelStyle(.titleAndIcon)
                    if let pasteError {
                        Text(pasteError)
                            .font(.footnote)
                            .foregroundStyle(DesignTokens.fault)
                    }
                }
            }
            .padding(DesignTokens.gutter)
            .readableContentWidth()
        }
        .background(DesignTokens.bgCanvas.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Server

private struct ServerStep: View {
    let model: AppModel
    let intent: OnboardingView.Intent
    @Binding var path: [OnboardingView.Step]
    @State private var browser = ServerBrowser()
    @State private var manual = ""
    @State private var checking: URL?
    @State private var errorText: String?
    @State private var unreachable: URL?

    var body: some View {
        List {
            Section {
                StepHeader(
                    title: "Find your server",
                    detail: "Benito keeps your family's log on a small server you run at home, like a Mac mini. Pick it below or type its address."
                )
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                ForEach(browser.found) { server in
                    Button {
                        check(server.url)
                    } label: {
                        HStack {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(server.name).foregroundStyle(DesignTokens.textPrimary)
                                    Text(server.url.absoluteString)
                                        .font(.footnote.monospaced())
                                        .foregroundStyle(DesignTokens.textSecondary)
                                }
                            } icon: {
                                Image(systemName: "server.rack").foregroundStyle(DesignTokens.sleep)
                            }
                            Spacer()
                            if checking == server.url { ProgressView() }
                        }
                    }
                    .disabled(checking != nil)
                }
                if browser.found.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking on this Wi-Fi…")
                            .foregroundStyle(DesignTokens.textSecondary)
                    }
                }
            } header: {
                Text("On this network")
            }
            .listRowBackground(BenitoGlassListRowBackground())

            Section {
                TextField("http://192.168.1.20:8787", text: $manual)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit(checkManual)
                    .font(.body.monospaced())
                Button {
                    checkManual()
                } label: {
                    HStack {
                        Text("Connect")
                        Spacer()
                        if checking != nil, !browser.found.contains(where: { $0.url == checking }) { ProgressView() }
                    }
                }
                .disabled(manual.trimmingCharacters(in: .whitespaces).isEmpty || checking != nil)
            } header: {
                Text("Or enter an address")
            } footer: {
                Text("Your Tailscale address works too. New to self-hosting? The README walks through running the server.")
            }
            .listRowBackground(BenitoGlassListRowBackground())

            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignTokens.fault)
                    if intent == .signIn, let unreachable {
                        Button("Continue anyway") { proceed(to: unreachable) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .readableContentWidth()
        .background(DesignTokens.bgCanvas.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if manual.isEmpty, !model.serverURLString.isEmpty { manual = model.serverURLString }
            browser.start()
        }
        .onDisappear { browser.stop() }
    }

    private func checkManual() {
        guard let normalized = ServerURLField.normalized(manual), let url = URL(string: normalized) else {
            errorText = "That doesn't look like a server address. Try something like http://192.168.1.20:8787."
            return
        }
        check(url)
    }

    private func check(_ url: URL) {
        checking = url
        errorText = nil
        unreachable = nil
        Task {
            let info = await AppModel.probe(url, timeout: 5)
            checking = nil
            if info != nil {
                proceed(to: url)
            } else {
                unreachable = url
                errorText = intent == .signIn
                    ? "Couldn't reach a Benito server at \(url.host() ?? url.absoluteString). Check you're on the same Wi-Fi or Tailscale."
                    : "Couldn't reach an up-to-date Benito server at \(url.host() ?? url.absoluteString). Check the address, your Wi-Fi or Tailscale, and that the server is updated."
            }
        }
    }

    private func proceed(to url: URL) {
        switch intent {
        case .startFamily:
            path.append(.details(server: url))
        case .signIn:
            Task {
                await model.switchServer(to: url)
                path.append(.signIn)
            }
        }
    }
}

// MARK: - New family

private struct FamilyDetailsStep: View {
    let model: AppModel
    let server: URL
    @State private var yourName = ""
    @State private var familyName = ""
    @State private var childName = ""
    @State private var isWorking = false
    @State private var errorText: String?
    @FocusState private var focus: Field?

    enum Field { case you, family, child }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StepHeader(title: "About your family", detail: "You can change these later.")
                field("Your name", "e.g. Alex", text: $yourName, .you, content: .givenName)
                field("Baby's name", "e.g. Sam", text: $childName, .child, content: .givenName)
                field("Family name", "e.g. The Garcias", text: $familyName, .family, content: .familyName)

                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.fault)
                }

                Button(action: start) {
                    Group {
                        if isWorking { ProgressView().tint(DesignTokens.onAccent) } else { Text("Create family") }
                    }
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: DesignTokens.thumbMin)
                    .foregroundStyle(DesignTokens.onAccent)
                    .background(DesignTokens.feed, in: Capsule(style: .continuous))
                }
                .buttonStyle(BenitoBorderlessButtonStyle())
                .disabled(!canStart)
                .opacity(canStart ? 1 : 0.5)

                Text("No email or password. This iPhone gets its own private key, kept in the Secure Enclave.")
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            .padding(DesignTokens.gutter)
            .readableContentWidth()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(DesignTokens.bgCanvas.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            applyScreenshotFill()
            focus = .you
        }
    }

    /// `SIMCTL_CHILD_BENITO_ONBOARDING_FILL` = "You|Baby|Family" prefills the form, and
    /// `…_AUTOCREATE=1` submits it, so screenshot runs reach a signed-in family hands-free.
    private func applyScreenshotFill() {
        let env = ProcessInfo.processInfo.environment
        guard yourName.isEmpty, let fill = env["BENITO_ONBOARDING_FILL"] else { return }
        let parts = fill.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return }
        (yourName, childName, familyName) = (parts[0], parts[1], parts[2])
        if env["BENITO_ONBOARDING_AUTOCREATE"] == "1" { start() }
    }

    private func field(
        _ label: String,
        _ prompt: String,
        text: Binding<String>,
        _ which: Field,
        content: UITextContentType
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DesignTokens.textSecondary)
            TextField(prompt, text: text)
                .textContentType(content)
                .focused($focus, equals: which)
                .submitLabel(which == .family ? .done : .next)
                .onSubmit {
                    switch which {
                    case .you: focus = .child
                    case .child: focus = .family
                    case .family: start()
                    }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: DesignTokens.thumbMin)
                .background(DesignTokens.bgCard, in: RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous))
        }
    }

    private func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canStart: Bool {
        !trimmed(yourName).isEmpty && !trimmed(childName).isEmpty && !isWorking
    }

    private func start() {
        guard canStart else { return }
        isWorking = true
        errorText = nil
        let family = trimmed(familyName).isEmpty ? "\(trimmed(childName))'s family" : trimmed(familyName)
        Task {
            defer { isWorking = false }
            do {
                try await model.startFamily(
                    server: server,
                    yourName: trimmed(yourName),
                    familyName: family,
                    childName: trimmed(childName)
                )
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

// MARK: - Existing account

private struct PasswordSignInStep: View {
    @Bindable var model: AppModel
    @State private var isWorking = false
    @FocusState private var focus: Field?

    enum Field { case email, password }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StepHeader(title: "Sign in", detail: "For accounts made with an email and password.")
                TextField("Email", text: $model.email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                    .modifier(OnboardingFieldStyle())
                SecureField("Password", text: $model.password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(signIn)
                    .modifier(OnboardingFieldStyle())

                if model.status.hasPrefix("Login failed") {
                    Label(model.status, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.fault)
                }

                Button(action: signIn) {
                    Group {
                        if isWorking { ProgressView().tint(DesignTokens.onAccent) } else { Text("Sign in") }
                    }
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: DesignTokens.thumbMin)
                    .foregroundStyle(DesignTokens.onAccent)
                    .background(DesignTokens.accentBlue, in: Capsule(style: .continuous))
                }
                .buttonStyle(BenitoBorderlessButtonStyle())
                .disabled(isWorking || model.email.isEmpty || model.password.isEmpty)

                Text("Connected to \(model.serverURLString)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            .padding(DesignTokens.gutter)
            .readableContentWidth()
        }
        .background(DesignTokens.bgCanvas.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            focus = .email
            applyScreenshotLogin()
        }
    }

    /// `SIMCTL_CHILD_BENITO_ONBOARDING_LOGIN` = "email|password" fills and submits the form against
    /// `BENITO_SERVER_URL`, so the password path can be checked end to end in the Simulator.
    private func applyScreenshotLogin() {
        let env = ProcessInfo.processInfo.environment
        guard model.email.isEmpty, let login = env["BENITO_ONBOARDING_LOGIN"] else { return }
        let parts = login.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        Task {
            if let server = env["BENITO_SERVER_URL"].flatMap(URL.init(string:)) {
                await model.switchServer(to: server)
            }
            (model.email, model.password) = (parts[0], parts[1])
            signIn()
        }
    }

    private func signIn() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            await model.login()
            isWorking = false
        }
    }
}

private struct OnboardingFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .frame(minHeight: DesignTokens.thumbMin)
            .background(DesignTokens.bgCard, in: RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous))
    }
}

// MARK: - Shared bits

private struct StepHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.largeTitle.bold())
            Text(detail)
                .foregroundStyle(DesignTokens.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }
}

private struct NumberedLine: View {
    let number: Int
    let text: String

    init(_ number: Int, _ text: String) {
        self.number = number
        self.text = text
    }

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(DesignTokens.sleep)
        }
    }
}
