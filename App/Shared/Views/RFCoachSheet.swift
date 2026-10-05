import SwiftUI
import SignalHiveCore

struct RFCoachRequest: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var subtitle: String
    var context: SignalDescriptionContext
    var operatorNote: String?

    init(
        title: String,
        subtitle: String = "",
        context: SignalDescriptionContext,
        operatorNote: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.context = context
        self.operatorNote = operatorNote
    }
}

/// Explains a signal: the generic AI answer sheet with the signal as its request.
struct RFCoachSheet: View {
    var request: RFCoachRequest

    var body: some View {
        AIAnswerSheet(
            navigationTitle: "RF Coach",
            title: request.title,
            subtitle: request.subtitle,
            note: request.operatorNote,
            makeRequest: { .explain(request.context, preferred: $0) },
            identity: request.id)
    }
}
